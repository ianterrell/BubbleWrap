module BubbleWrap

  SETTINGS = {}

  # The HTTP module provides a simple interface to make HTTP requests.
  #
  # TODO: preflight support, easier/better cookie support, better error handling
  module HTTP

    # Make a GET request and process the response asynchronously via a block.
    #
    # @examples
    #  # Simple GET request printing the body
    #   BubbleWrap::HTTP.get("https://api.github.com/users/mattetti") do |response|
    #     p response.body.to_str
    #   end
    #
    #  # GET request with basic auth credentials
    #   BubbleWrap::HTTP.get("https://api.github.com/users/mattetti", {credentials: {username: 'matt', password: 'aimonetti'}}) do |response|
    #     p response.body.to_str # prints the response's body
    #   end
    #
    def self.get(url, options={}, &block)
      create_query url, :get, options, &block
    end
    
    # Make a POST request
    def self.post(url, options={}, &block)
      create_query url, :post, options, &block
    end
    
    # Make a PUT request
    def self.put(url, options={}, &block)
      create_query url, :put, options, &block
    end
    
    # Make a DELETE request
    def self.delete(url, options={}, &block)
      create_query url, :delete, options, &block
    end

    # Make a HEAD request
    def self.head(url, options={}, &block)
      create_query url, :head, options, &block
    end

    # Make a PATCH request
    def self.patch(url, options={}, &block)
      create_query url, :patch, options, &block
    end

    private
    def self.create_query(url, method, options, &block)
      options[:action] = block if block_given?
      HTTP::Query.new( url, method, options )
    end

    # Response class wrapping the results of a Query's response
    class Response
      attr_reader :body
      attr_reader :headers
      attr_accessor :status_code, :error_message
      attr_reader :url

      def initialize(values={})
        self.update(values)
      end

      def update(values)
        values.each do |k,v|
          self.instance_variable_set("@#{k}", v)
        end
      end

      def ok?
        status_code.to_s =~ /20\d/ ? true : false
      end

    end

    # Class wrapping NSConnection and often used indirectly by the BubbleWrap::HTTP module methods.
    class Query
      attr_accessor :request
      attr_accessor :connection
      attr_accessor :credentials # username & password has a hash
      attr_accessor :proxy_credential # credential supplied to proxy servers
      attr_accessor :post_data
      attr_reader   :method

      attr_reader :response
      attr_reader :status_code
      attr_reader :response_headers
      attr_reader :response_size
      attr_reader :options

      # ==== Parameters
      # url<String>:: url of the resource to download
      # http_method<Symbol>:: Value representing the HTTP method to use
      # options<Hash>:: optional options used for the query
      #
      # ==== Options
      # :payload<String>   - data to pass to a POST, PUT, DELETE query.
      # :delegator         - Proc, class or object to call when the file is downloaded.
      # a proc will receive a Response object while the passed object
      # will receive the handle_query_response method
      # :headers<Hash>     - headers send with the request
      # Anything else will be available via the options attribute reader.
      #
      def initialize(url, http_method = :get, options={})
        @method = http_method.upcase.to_s
        @delegator = options.delete(:action) || self
        @payload = options.delete(:payload)
        @credentials = options.delete(:credentials) || {}
        @credentials = {:username => '', :password => ''}.merge(@credentials)
        @timeout = options.delete(:timeout) || 30.0
        @headers = escape_line_feeds(options.delete :headers)
        @cache_policy = options.delete(:cache_policy) || NSURLRequestUseProtocolCachePolicy
        @options = options
        @response = HTTP::Response.new
        initiate_request(url)
        connection.start
        UIApplication.sharedApplication.networkActivityIndicatorVisible = true
        connection
      end

      def generate_get_params(payload, prefix=nil)
        list = []
        payload.each do |k,v|
          if v.is_a?(Hash)
            new_prefix = prefix ? "#{prefix}[#{k.to_s}]" : k.to_s
            param = generate_get_params(v, new_prefix)
          else
            param = prefix ? "#{prefix}[#{k}]=#{v}" : "#{k}=#{v}"
          end
          list << param
        end
        return list.flatten
      end

      def initiate_request(url_string)
        # http://developer.apple.com/documentation/Cocoa/Reference/Foundation/Classes/nsrunloop_Class/Reference/Reference.html#//apple_ref/doc/constant_group/Run_Loop_Modes
        # NSConnectionReplyMode
        
        unless @payload.nil?
          if @payload.is_a?(Hash)
            params   = generate_get_params(@payload)
            @payload = params.join("&")
          end
          url_string = "#{url_string}?#{@payload}" if @method == "GET"
        end
        #this method needs a refactor when the specs are done. (especially this utf8 escaping part)
        log "BubbleWrap::HTTP building a NSRequest for #{url_string}"
        @url = NSURL.URLWithString(url_string.stringByAddingPercentEscapesUsingEncoding NSUTF8StringEncoding)
        @request = NSMutableURLRequest.requestWithURL(@url,
                                                      cachePolicy:@cache_policy,
                                                      timeoutInterval:@timeout)
        @request.setHTTPMethod @method
        @request.setAllHTTPHeaderFields(@headers) if @headers

        # @payload needs to be converted to data
        unless @method == "GET" || @payload.nil?
          @payload = @payload.to_s.dataUsingEncoding(NSUTF8StringEncoding)
          @request.setHTTPBody @payload
        end

        # NSHTTPCookieStorage.sharedHTTPCookieStorage
        @connection = create_connection(request, self)
        patch_nsurl_request
      end

      def connection(connection, didReceiveResponse:response)
        @status_code = response.statusCode
        @response_headers = response.allHeaderFields
        @response_size = response.expectedContentLength.to_f
      end

      # This delegate method get called every time a chunk of data is being received
      def connection(connection, didReceiveData:received_data)
        @received_data ||= NSMutableData.new
        @received_data.appendData(received_data)
      end

      def connection(connection, willSendRequest:request, redirectResponse:redirect_response)
        log "HTTP redirected #{request.description}"
        new_request = request.mutableCopy
        # new_request.setValue(@credentials.inspect, forHTTPHeaderField:'Authorization') # disabled while we figure this one out
        new_request.setAllHTTPHeaderFields(@headers) if @headers
        @connection.cancel
        @connection = create_connection(new_request, self)
        new_request
      end

      def connection(connection, didFailWithError: error)
        UIApplication.sharedApplication.networkActivityIndicatorVisible = false
        @request.done_loading!
        log "HTTP Connection failed #{error.localizedDescription}"
        @response.error_message = error.localizedDescription
        call_delegator_with_response
      end


      # The transfer is done and everything went well
      def connectionDidFinishLoading(connection)
        UIApplication.sharedApplication.networkActivityIndicatorVisible = false
        @request.done_loading!
        # copy the data in a local var that we will attach to the response object
        response_body = NSData.dataWithData(@received_data) if @received_data
        @response.update(status_code: status_code, body: response_body, headers: response_headers, url: @url)

        call_delegator_with_response
      end

      def connection(connection, didReceiveAuthenticationChallenge:challenge)

        if (challenge.previousFailureCount == 0)
          # by default we are keeping the credential for the entire session
          # Eventually, it would be good to let the user pick one of the 3 possible credential persistence options:
          # NSURLCredentialPersistenceNone,
          # NSURLCredentialPersistenceForSession,
          # NSURLCredentialPersistencePermanent
          log "auth challenged, answered with credentials: #{credentials.inspect}"
          new_credential = NSURLCredential.credentialWithUser(credentials[:username], password:credentials[:password], persistence:NSURLCredentialPersistenceForSession)
          challenge.sender.useCredential(new_credential, forAuthenticationChallenge:challenge)
        else
          challenge.sender.cancelAuthenticationChallenge(challenge)
          log 'Auth Failed :('
        end
      end


      private

      def log(message)
        NSLog message if SETTINGS[:debug]
      end

      def escape_line_feeds(hash)
        return nil if hash.nil?
        escaped_hash = {}
        
        hash.each{|k,v| escaped_hash[k] = v.gsub("\n", '\\n') }
        escaped_hash
      end

      def patch_nsurl_request
        @request.instance_variable_set("@done_loading", false)
        
        def @request.done_loading; @done_loading; end
        def @request.done_loading!; @done_loading = true; end
      end

      def call_delegator_with_response
        if @delegator.respond_to?(:call)
          @delegator.call( @response, self )
        end
      end

      # This is a temporary method used for mocking.
      def create_connection(request, delegate)
        NSURLConnection.connectionWithRequest(request, delegate:delegate)
      end
    end
  end
end
