require "../morganite"

Signal::INT.trap do
  puts "Shutting down Morganite..."
  Morganite.stop
end

Signal::TERM.trap do
  Morganite.stop
end

Morganite.start
Morganite.wait
