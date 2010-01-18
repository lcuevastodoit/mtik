############################################################################
## A Ruby library implementing the Ruby MikroTik API
############################################################################
## Author::    Aaron D. Gifford - http://www.aarongifford.com/
## Copyright:: Copyright (c) 2009-2010, InfoWest, Inc.
## License::   BSD license
##
## Redistribution and use in source and binary forms, with or without
## modification, are permitted provided that the following conditions
## are met:
## 1. Redistributions of source code must retain the above copyright
##    notice, the above list of authors and contributors, this list of
##    conditions and the following disclaimer.
## 2. Redistributions in binary form must reproduce the above copyright
##    notice, this list of conditions and the following disclaimer in the
##    documentation and/or other materials provided with the distribution.
## 3. Neither the name of the author(s) or copyright holder(s) nor the
##    names of any contributors may be used to endorse or promote products
##    derived from this software without specific prior written permission.
##
## THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S), AUTHOR(S) AND
## CONTRIBUTORS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
## INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
## AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL
## IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), AUTHOR(S), OR CONTRIBUTORS BE
## LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
## DCONSEQUENTIAL AMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
## SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
## INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
## CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
## ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
## THE POSSIBILITY OF SUCH DAMAGE.
############################################################################

module MTik
  require 'mtik/error.rb'
  require 'mtik/timeouterror.rb'
  require 'mtik/fatalerror.rb'
  require 'mtik/reply.rb'
  require 'mtik/request.rb'
  require 'mtik/connection.rb'

  ## Default MikroTik RouterOS API TCP port:
  PORT = 8728
  ## Default username to use if none is specified:
  USER = 'admin'
  ## Default password to use if none is specified:
  PASS = ''
  ## Connection timeout default -- *NOT USED* 
  CONN_TIMEOUT = 60
  ## Command timeout -- The maximum number of seconds to wait for more
  ## API data when expecting one or more command responses.
  CMD_TIMEOUT  = 60

  @verbose = false
  @debug   = false

  ## Access the current verbose setting (boolean)
  def self.verbose
    return @verbose
  end

  ## Change the current verbose setting (boolean)
  def self.verbose=(x)
    return @verbose = x
  end

  ## Access the current debug setting (boolean)
  def self.debug
    return @debug
  end

  ## Change the current debug setting (boolean)
  def self.debug=(x)
    return @debug = x
  end


  ## Act as an interactive client with the device, accepting user
  ## input from STDIN.
  def self.interactive_client(host, user, pass)
    old_verbose = MTik::verbose
    MTik::verbose = true
    begin
      tk = MTik::Connection.new(:host => host, :user => user, :pass => pass)
    rescue MTik::Error, Errno::ECONNREFUSED => e
      print "=== LOGIN ERROR: #{e.message}\n"
      exit
    end

    while true
      print "\nCommand (/quit to end): "
      cmd = STDIN.gets.sub(/^\s+/, '').sub(/\s*[\r\n]*$/, '')
      maxreply = 0
      m = /^(\d+):/.match(cmd)
      unless m.nil?
        maxreply = m[1].to_i
        cmd.sub!(/^\d+:/, '')
      end
      args  = cmd.split(/\s+/)
      cmd   = args.shift
      next if cmd == ''
      break if cmd == '/quit'
      unless /^(?:\/[a-zA-Z0-9]+)+$/.match(cmd)
        print "=== INVALID COMMAND: #{cmd}\n" if MTik::debug || MTik::verbose
        break
      end
      print "=== COMMAND: #{cmd}\n" if MTik::debug || MTik::verbose
      trap  = false
      count = 0
      state = 0
      begin
        tk.send_request(false, cmd, args) do |req, sentence|
          if sentence.key?('!trap')
            trap = sentence
            print "=== TRAP: '" + (trap.key?('message') ? trap['message'] : "UNKNOWN") + "'\n\n"
          elsif sentence.key?('!re')
            count += 1
            ## Auto-cancel '/tool/fetch' commands or any others that the user
            ## specified a number of replies to auto-cancel at:
            if (
              cmd == '/tool/fetch' && sentence.key?('status') && sentence['status'] == 'finished'
            ) || (maxreply > 0 && count == maxreply)
              state = 2
              tk.send_request(true, '/cancel', '=tag=' + req.tag) do |req, sentence|
                state = 1
              end
            end
          elsif !sentence.key?('!done') && !sentence.key?('!fatal')
            raise MTik::Error.new("Unknown or unexpected reply sentence type.")
          end
          if state == 0 && req.done?
            state = 1
          end
        end
        while state != 1
          tk.wait_for_reply
        end
      rescue MTik::Error => e
        print "=== ERROR: #{e.message}\n"
      end
      unless tk.connected?
        begin
          tk.login
        rescue MTik::Error => e
          print "=== LOGIN ERROR: #{e.message}\n"
          tk.close
          exit
        end
      end
    end
 
    reply = tk.get_reply('/quit')
    unless reply[0].key?('!fatal')
      raise MTik::Error.new("Unexpected response to '/quit' command.")
    end

    ## Extract any device-provided message from the '!fatal' response
    ## to the /quit command:
    print "=== SESSION TERMINATED"
    message = ''
    reply[0].each_key do |key|
      next if key == '!fatal'
      message += "'#{key}'"
      unless reply[0][key].nil?
        message += " => '#{reply[0][key]}'"
      end
    end
    if message.length > 0
      print ": " + message
    else
      print " ==="
    end
    print "\n\n"

    unless tk.connected?
      print "=== Disconnected ===\n\n"
    else
      ## In theory, this should never execute:
      tk.close
    end

    MTik::verbose = old_verbose
  end


  ## An all-in-one function to instantiate, connect, send one or
  ## more commands, retrieve the response(s), close the connection,
  ## and return the response(s).
  ##
  ## *WARNING* :: If you use this call with an API command like
  ## +/tool/fetch+ it will forever keep reading replies, never
  ## returning.  So do _NOT_ use this with any API command that does
  ## not complete with a "!done" with no additional interaction.
  def self.command(args)
    tk = MTik::Connection.new(
      :host => args[:host],
      :user => args[:user],
      :pass => args[:pass],
      :port => args[:port],
      :conn_timeout => args[:conn_timeout],
      :cmd_timeout  => args[:cmd_timeout]
    )
    cmd = args[:command]
    replies = Array.new
    if cmd.is_a?(String)
      ## Single command, no arguments
      cmd = [ cmd ]
    end
    if cmd.is_a?(Array)
      ## Either a single command with arguments
      ## or multiple commands:
      if cmd[0].is_a?(Array)
        ## Array of arrays means multiple commands:
        cmd.each do |c|
          tk.send_request(true, c[0], c[1,c.length-1]) do |req, sentence|
            replies.push(req.reply)
          end
        end
      else
        ## Single command
        tk.send_request(true, cmd[0], cmd[1,cmd.length-1]) do |req, sentence|
          replies.push(req.reply)
        end
      end
    else
      raise ArgumentError.new("invalid command argument")
    end
    tk.wait_all
    tk.get_reply('/quit')
    tk.close
    return replies
  end

end

