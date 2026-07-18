require "./job"

module Morganite
  module ClientMiddleware
    @@middlewares = [] of ClientMiddleware

    def self.use(middleware : ClientMiddleware)
      @@middlewares << middleware
    end

    def self.clear
      @@middlewares.clear
    end

    def self.invoke(job : Job, on_done : -> Nil)
      chain = on_done
      @@middlewares.reverse_each do |middleware|
        previous = chain
        chain = -> { middleware.call(job, previous) }
      end
      chain.call
    end

    abstract def call(job : Job, next_middleware : -> Nil)
  end
end
