const oop_mod = @import("oop.zig");
const Oop = oop_mod.Oop;

// Well-known objects produced by bootstrap. All initialized to NIL so
// that `classOf` returns nil for sentinels before bootstrap completes
// (useful for "did the world come up?" checks).
pub const Globals = struct {
    // Kernel classes — the metaclass infrastructure.
    object_class: Oop = oop_mod.NIL,
    behavior_class: Oop = oop_mod.NIL,
    class_description_class: Oop = oop_mod.NIL,
    class_class: Oop = oop_mod.NIL,
    metaclass_class: Oop = oop_mod.NIL,

    // Sentinel classes — what `classOf` returns for nil/true/false.
    undefined_class: Oop = oop_mod.NIL,
    boolean_class: Oop = oop_mod.NIL,
    true_class: Oop = oop_mod.NIL,
    false_class: Oop = oop_mod.NIL,

    // Tagged-int class.
    smallinteger_class: Oop = oop_mod.NIL,
    small_float_class: Oop = oop_mod.NIL,
    large_positive_integer_class: Oop = oop_mod.NIL,
    large_negative_integer_class: Oop = oop_mod.NIL,

    // Concrete leaf classes.
    byte_array_class: Oop = oop_mod.NIL,
    string_class: Oop = oop_mod.NIL,
    symbol_class: Oop = oop_mod.NIL,
    array_class: Oop = oop_mod.NIL,
    dictionary_class: Oop = oop_mod.NIL,
    compiled_method_class: Oop = oop_mod.NIL,
    frame_class: Oop = oop_mod.NIL,
    block_closure_class: Oop = oop_mod.NIL,

    // AST node classes — one per kind. AST is now in-image, GC'd, and
    // saved with the rest of the heap.
    literal_node_class: Oop = oop_mod.NIL,
    var_ref_node_class: Oop = oop_mod.NIL,
    assign_node_class: Oop = oop_mod.NIL,
    send_node_class: Oop = oop_mod.NIL,
    super_send_node_class: Oop = oop_mod.NIL,
    block_node_class: Oop = oop_mod.NIL,
    seq_node_class: Oop = oop_mod.NIL,
    ret_node_class: Oop = oop_mod.NIL,

    exception_class: Oop = oop_mod.NIL,
    // Reified failed send. The DNU dispatch path allocates one of
    // these and hands it to the receiver's doesNotUnderstand:.
    message_class: Oop = oop_mod.NIL,

    // Concurrency classes (loaded after the kernel is wired so their
    // metaclass parents already exist). The Processor singleton —
    // an instance of ProcessorScheduler — is bound in `Smalltalk`
    // under the name "Processor".
    process_class: Oop = oop_mod.NIL,
    semaphore_class: Oop = oop_mod.NIL,
    scheduler_class: Oop = oop_mod.NIL,
    processor: Oop = oop_mod.NIL,
    file_stream_class: Oop = oop_mod.NIL,
    socket_class: Oop = oop_mod.NIL,

    // Pre-interned state symbols — read by Vm.invokeBlock's fork path
    // and by the wait/signal primitives.
    sym_runnable: Oop = oop_mod.NIL,
    sym_suspended: Oop = oop_mod.NIL,
    sym_waiting: Oop = oop_mod.NIL,
    sym_terminated: Oop = oop_mod.NIL,

    // The SystemDictionary instance, conventionally bound to `Smalltalk`.
    smalltalk: Oop = oop_mod.NIL,

    // Symbol intern table — Dictionary with interned Symbols as keys
    // and NIL values. Every Symbol with given bytes is unique. NIL
    // before bootstrap reaches the symbol-interning phase; once set,
    // dict.newSymbol routes every allocation through it.
    symbol_table: Oop = oop_mod.NIL,

    // Pre-interned Symbols for the pseudo-variables and frequently-used
    // names. Comparing var_ref's Symbol Oop to one of these is O(1)
    // and replaces byte-string compares in the eval hot path.
    sym_nil: Oop = oop_mod.NIL,
    sym_true: Oop = oop_mod.NIL,
    sym_false: Oop = oop_mod.NIL,
    sym_smalltalk: Oop = oop_mod.NIL,
    sym_thisContext: Oop = oop_mod.NIL,
    sym_self: Oop = oop_mod.NIL,
    // Selectors primitives dispatch internally (whileTrue:, ifTrue:,
    // on:do:, ensure: all send `value`/`value:`). Pre-intern so the
    // hot dispatch path doesn't re-intern bytes every iteration.
    sym_value: Oop = oop_mod.NIL,
    sym_value_colon: Oop = oop_mod.NIL,
    // SmallInteger arithmetic selectors — used for the AST-level fast
    // path that bypasses method lookup when both operands are tagged
    // ints. Caveat: a user-defined override on SmallInteger is invisible
    // to this path (Pharo has the same limitation for inline primitives).
    sym_plus: Oop = oop_mod.NIL,
    sym_minus: Oop = oop_mod.NIL,
    sym_times: Oop = oop_mod.NIL,
    sym_lt: Oop = oop_mod.NIL,
    sym_le: Oop = oop_mod.NIL,
    sym_gt: Oop = oop_mod.NIL,
    sym_ge: Oop = oop_mod.NIL,
    // Selector that the printNl primitive sends to dispatch through
    // the Smalltalk-side printOn: protocol (defined in stdlib).
    sym_printString: Oop = oop_mod.NIL,
    // Slow-path DNU dispatch lookup uses this pre-interned symbol.
    sym_does_not_understand: Oop = oop_mod.NIL,
};
