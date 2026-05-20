module Crystal::JIT
  # C-ABI bridge from the host SIGCHLD reaper into the JIT module's
  # `SignalChildHandler.notify_reaped`. Spliced into the user prelude;
  # `Session#install_signal_bridge` looks the fun up by name.
  JIT_SIGCHLD_BRIDGE_SOURCE = {{ read_file("#{__DIR__}/embedded_sources/sigchld_bridge_source.cr") }}
end
