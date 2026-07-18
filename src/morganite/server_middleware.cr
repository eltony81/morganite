require "./job"
require "./worker"

module Morganite
  module ServerMiddleware
    @@middlewares = [] of ServerMiddleware

    def self.use(middleware : ServerMiddleware)
      @@middlewares << middleware
    end

    def self.clear
      @@middlewares.clear
    end

    def self.invoke(job : Job, worker : Worker, queue : String, on_done : -> Nil)
      chain = on_done
      @@middlewares.reverse_each do |middleware|
        previous = chain.as(-> Nil)
        chain = -> { middleware.call(job, worker, queue, previous); nil }
      end
      chain.call
    end

    abstract def call(job : Job, worker : Worker, queue : String, next_middleware : -> Nil)
  end
end
