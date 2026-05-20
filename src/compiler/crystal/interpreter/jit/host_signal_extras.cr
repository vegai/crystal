require "../../../../crystal/system/unix/signal"

# JIT REPL bridge for `Crystal::System::SignalChildHandler`. Kept out
# of `signal.cr` so AOT user binaries do not carry the field, setter,
# or dispatch.
#
# Lock order: host signal `@@mutex` -> JIT signal `@@mutex` -> JIT
# `EventLoop.@@registry_mutex`. The two `@@mutex` copies must remain
# distinct objects; the JIT module's class-var storage uses
# LinkOnceODR linkage so ORC resolves a fresh copy at JIT-link time,
# even though `link_symbols_from_current_process` exposes the host
# symbol table. A future linker tweak that merges them would silently
# deadlock here.
module Crystal::System::SignalChildHandler
  @@external_reaper : Proc(LibC::PidT, Int32, Bool)? = nil

  def self.external_reaper=(callback : Proc(LibC::PidT, Int32, Bool)?) : Nil
    @@mutex.synchronize { @@external_reaper = callback }
  end

  private def self.external_reap_claimed?(pid : LibC::PidT, exit_code : Int32) : Bool
    return false unless reaper = @@external_reaper
    reaper.call(pid, exit_code)
  end
end
