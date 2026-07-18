require "../spec_helper"

describe Morganite::Hooks do
  before_each do
    Morganite::Hooks.clear
  end

  it "runs registered startup hooks" do
    called = false
    Morganite::Hooks.on_startup { called = true }
    Morganite::Hooks.run_startup
    called.should be_true
  end

  it "runs registered shutdown hooks" do
    called = false
    Morganite::Hooks.on_shutdown { called = true }
    Morganite::Hooks.run_shutdown
    called.should be_true
  end

  it "runs before first fetch hooks" do
    called = false
    Morganite::Hooks.before_first_fetch { called = true }
    Morganite::Hooks.run_before_first_fetch
    called.should be_true
  end

  it "runs after last fetch hooks" do
    called = false
    Morganite::Hooks.after_last_fetch { called = true }
    Morganite::Hooks.run_after_last_fetch
    called.should be_true
  end
end
