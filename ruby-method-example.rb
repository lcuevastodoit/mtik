def conn (command)
 
      p MTik::command(       
        
        :host=>Figaro.env.mtik_host,
        :port=>Figaro.env.mtik_port,
        :user=>Figaro.env.mtik_user,
        :pass=>Figaro.env.mtik_pwd,
        #:ssl => true,        
        :command=>command,
        :unencrypted_plaintext => true
        
      )
  
    end
