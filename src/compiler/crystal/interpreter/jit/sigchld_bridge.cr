module Crystal::JIT
  # Crystal source for the C-ABI fun that the host's SIGCHLD reaper calls
  # to forward reaped child pids into this JIT submission's LinkOnceODR
  # copy of SignalChildHandler. Without it, JIT-emitted Process.run
  # registers its waiter in the JIT's @@waiting while the host's reaper
  # only touches the host's @@waiting; the JIT waiter then blocks forever.
  # Session#install_signal_bridge takes the fun's address via
  # LLJIT#lookup and installs it as the host's external_reaper.
  #
  # The body lives in `embedded_sources/sigchld_bridge_source.cr` for
  # editor tooling. The subdirectory keeps it out of
  # `require "./interpreter/jit/*"`.
  JIT_SIGCHLD_BRIDGE_SOURCE = {{ read_file("#{__DIR__}/embedded_sources/sigchld_bridge_source.cr") }}
end
