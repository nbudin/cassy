module Cassy
  class SessionsController < ApplicationController
    include Cassy::Utils
    include Cassy::CAS

    def new
      # optional params
      @service = clean_service_url(params['service'])
      @renew = params['renew']
      @gateway = params['gateway'] == 'true' || params['gateway'] == '1'

      if tgc = request.cookies['tgt']
        tgt, tgt_error = validate_ticket_granting_ticket(tgc)
      end

      if tgt and !tgt_error
        flash.now[:notice] = "You are currently logged in as '%s'. If this is not you, please log in below." % tgt.username
      end

      if params['redirection_loop_intercepted']
        flash.now[:error] = "The client and server are unable to negotiate authentication. Please try logging in again later."
      end

      begin
        if @service
          if !@renew && tgt && !tgt_error
            st = generate_service_ticket(@service, tgt.username, tgt)
            service_with_ticket = service_uri_with_ticket(@service, st)
            redirect_to service_with_ticket, :status => 303 # response code 303 means "See Other" (see Appendix B in CAS Protocol spec)
          elsif @gateway
            redirect @service, 303
          end
        elsif @gateway
          flash.now[:error] = "The server cannot fulfill this gateway request because no service parameter was given."
        end
      rescue URI::InvalidURIError
        flash.now[:error] = "The target service your browser supplied appears to be invalid. Please contact your system administrator for help."
      end

      @lt = generate_login_ticket.ticket
    end
    
    def create
      setup_from_params!

      if error = validate_login_ticket(@lt)
        flash.now[:error] = error
        @lt = generate_login_ticket.ticket
        render(:new, :status => 500) and return
      end
      
      # generate another login ticket to allow for re-submitting the form after a post
      @lt = generate_login_ticket.ticket

      logger.debug("Logging in with username: #{@username}, lt: #{@lt}, service: #{@service}, auth: #{settings[:auth].inspect}")

      begin
        if valid_credentials?
          # 3.6 (ticket-granting cookie)
          tgt = generate_ticket_granting_ticket(@username, @extra_attributes)
          response.set_cookie('tgt', tgt.to_s)

          if @service.blank?
            flash.now[:notice] = "You have successfully logged in."
            render :new
          else
            @st = generate_service_ticket(@service, @username, tgt)

            begin
              service_with_ticket = service_uri_with_ticket(@service, @st)
              redirect_to service_with_ticket, :status => 303 # response code 303 means "See Other" (see Appendix B in CAS Protocol spec)
            rescue URI::InvalidURIError
              flash.now[:error] = "The target service your browser supplied appears to be invalid. Please contact your system administrator for help."
            end
          end
        else
          incorrect_credentials!
        end
      rescue Cassy::AuthenticatorError => e
        logger.error(e)
        # generate another login ticket to allow for re-submitting the form
        @lt = generate_login_ticket.ticket
        flash[:error] = e.to_s
        render :status => 401
      end
    end
    
    def destroy
      # The behaviour here is somewhat non-standard. Rather than showing just a blank
      # "logout" page, we take the user back to the login page with a "you have been logged out"
      # message, allowing for an opportunity to immediately log back in. This makes it
      # easier for the user to log out and log in as someone else.
      @service = clean_service_url(params['service'] || params['destination'])
      @continue_url = params['url']

      @gateway = params['gateway'] == 'true' || params['gateway'] == '1'

      tgt = Cassy::TicketGrantingTicket.find_by_ticket(request.cookies['tgt'])

      response.delete_cookie 'tgt'

      if tgt
        Cassy::TicketGrantingTicket.transaction do
          pgts = Cassy::ProxyGrantingTicket.find(:all,
            :conditions => [ActiveRecord::Base.connection.quote_table_name(Cassy::ServiceTicket.table_name)+".username = ?", tgt.username],
            :include => :service_ticket)
          pgts.each do |pgt|
            pgt.destroy
          end

          tgt.destroy
        end

        # $LOG.info("User '#{tgt.username}' logged out.")
      else
        # $LOG.warn("User tried to log out without a valid ticket-granting ticket.")
      end
      
      flash[:notice] = "You have successfully logged out."
      @lt = generate_login_ticket

      if @gateway && @service
        redirect_to @service, :status => 303
      else
        # TODO: Do not hardcode "/users/service"
        redirect_to "/cas/login?service=#{@service}/users/service"
      end
    end
    
    def service_validate
      # required
      @service = clean_service_url(params['service'])
      @ticket = params['ticket']
      # optional
      @renew = params['renew']

      st, @error = validate_service_ticket(@service, @ticket)
      @success = st && !@error

      if @success
        @username = st.username
        if @pgt_url
          pgt = generate_proxy_granting_ticket(@pgt_url, st)
          @pgtiou = pgt.iou if pgt
        end
        @extra_attributes = st.granted_by_tgt.extra_attributes || {}
      end

      status = response_status_from_error(@error) if @error

      render :proxy_validate, :layout => false, :status => status || 200
    end
    
    def proxy_validate

      # required
      @service = clean_service_url(params['service'])
      @ticket = params['ticket']
      # optional
      @pgt_url = params['pgtUrl']
      @renew = params['renew']

      @proxies = []

      t, @error = validate_proxy_ticket(@service, @ticket)
      @success = t && !@error

      @extra_attributes = {}
      if @success
        @username = t.username

        if t.kind_of? Cassy::ProxyTicket
          @proxies << t.granted_by_pgt.service_ticket.service
        end

        if @pgt_url
          pgt = generate_proxy_granting_ticket(@pgt_url, t)
          @pgtiou = pgt.iou if pgt
        end

        @extra_attributes = t.granted_by_tgt.extra_attributes || {}
      end

      status = response_status_from_error(@error) if @error

      render :proxy_validate, :layout => false, :status => status || 200
      
    end
    
    private
    
    def response_status_from_error(error)
      case error.code.to_s
      when /^INVALID_/, 'BAD_PGT'
        422
      when 'INTERNAL_ERROR'
        500
      else
        500
      end
    end
    
    def setup_from_params!
      # 2.2.1 (optional)
      @service = clean_service_url(params['service'])

      # 2.2.2 (required)
      @username = params[:username].strip
      @password = params[:password]
      @lt = params['lt']
    end

    # Initializes authenticator, returns true / false depending on if user credentials are accurate
    def valid_credentials?
      setup_from_params!
      @extra_attributes = {}
      # Should probably be moved out of the request cycle and into an after init hook on the engine
      auth_settings = Cassy.config["authenticator"]
      @authenticator = auth_settings["class"].constantize
      @authenticator.configure(auth_settings)

      credentials = { :username => @username,
                      :password => @password,
                      :service => @service,
                      :request => @env
                    }

      @user = @authenticator.find_user(credentials)

      valid = @authenticator.validate(credentials)
      if valid
        @authenticator.extra_attributes_to_extract.each do |attr|
          puts "EXTRACTING A NEW ATTRIBUTE: #{attr}"
          @extra_attributes[attr] = @user.send(attr)
        end
      end
      
      return valid
    end
    
    def incorrect_credentials!
      flash.now[:error] = "Incorrect username or password."
      render :new, :status => 401
    end
  end
end