module Morganite
  module Hooks
    @@on_startup = [] of -> Nil
    @@on_shutdown = [] of -> Nil
    @@before_first_fetch = [] of -> Nil
    @@after_last_fetch = [] of -> Nil

    def self.on_startup(&block : -> Nil)
      @@on_startup << block
    end

    def self.on_shutdown(&block : -> Nil)
      @@on_shutdown << block
    end

    def self.before_first_fetch(&block : -> Nil)
      @@before_first_fetch << block
    end

    def self.after_last_fetch(&block : -> Nil)
      @@after_last_fetch << block
    end

    def self.clear
      @@on_startup.clear
      @@on_shutdown.clear
      @@before_first_fetch.clear
      @@after_last_fetch.clear
    end

    def self.run_startup
      @@on_startup.each(&.call)
    end

    def self.run_shutdown
      @@on_shutdown.each(&.call)
    end

    def self.run_before_first_fetch
      @@before_first_fetch.each(&.call)
    end

    def self.run_after_last_fetch
      @@after_last_fetch.each(&.call)
    end
  end
end
