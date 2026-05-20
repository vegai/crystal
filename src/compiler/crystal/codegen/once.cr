require "./codegen"

class Crystal::CodeGenVisitor
  ONCE_STATE = "~ONCE_STATE"

  def once_init
    if once_init_fun = typed_fun?(@main_mod, ONCE_INIT)
      # legacy (kept for backward compatibility): the compiler must save the
      # state returned by __crystal_once_init
      once_init_fun = check_main_fun ONCE_INIT, once_init_fun

      once_state_global = @main_mod.globals.add(once_init_fun.type.return_type, ONCE_STATE)
      module_local_linkage(once_state_global)
      once_state_global.initializer = once_init_fun.type.return_type.null

      state = call once_init_fun
      store state, once_state_global
    end
  end

  def run_once(flag, func : LLVMTypedFunction)
    # repl_mode bypasses `__crystal_once`. Under non-EC builds the inline
    # load+cond+store is safe because the REPL is single-threaded. Under
    # EC builds concurrent fibers can both pass the flag check and
    # double-initialize; we accept that for class-var initializers
    # because the alternative (`__crystal_once`) leaves a dangling
    # Operation in `@@operations` on a raising init, which the JIT can't
    # currently unwind across submissions.
    if @program.repl_state?
      return run_once_inline(flag, func)
    end

    once_fun = main_fun(ONCE)
    once_fun_params = once_fun.func.params
    once_initializer_type = once_fun_params.last.type # must be Void*
    initializer = pointer_cast(func.func.to_value, once_initializer_type)

    if once_fun_params.size == 2
      args = [flag, initializer]
    else
      # legacy (kept for backward compatibility): the compiler must pass the
      # state returned by __crystal_once_init to __crystal_once as the first
      # argument
      once_init_fun = main_fun(ONCE_INIT)
      once_state_type = once_init_fun.type.return_type # must be Void*

      once_state_global = @llvm_mod.globals[ONCE_STATE]? || begin
        global = @llvm_mod.globals.add(once_state_type, ONCE_STATE)
        global.linkage = LLVM::Linkage::External
        global
      end

      state = load(once_state_type, once_state_global)
      args = [state, flag, initializer]
    end

    call once_fun, args
  end

  private def run_once_inline(flag, func : LLVMTypedFunction)
    init_block = new_block "once_init"
    skip_block = new_block "once_skip"

    flag_val = load(@llvm_context.int1, flag)
    cond flag_val, skip_block, init_block

    position_at_end init_block
    store @llvm_context.int1.const_int(1), flag
    call func, [] of LLVM::Value
    br skip_block

    position_at_end skip_block
    @last = llvm_nil
  end
end
