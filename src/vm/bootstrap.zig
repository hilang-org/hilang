const std = @import("std");
const oop_mod = @import("oop.zig");
const object = @import("object.zig");
const heap_mod = @import("heap.zig");
const globals_mod = @import("globals.zig");
const dict_mod = @import("dict.zig");
const method_mod = @import("method.zig");
const prims = @import("prims.zig");

const Oop = oop_mod.Oop;
const Heap = heap_mod.Heap;
const Globals = globals_mod.Globals;

// Bootstraps the faithful Smalltalk kernel. After this returns, every
// reachable object has a valid class pointer and the SystemDictionary
// holds bindings for every named class.
//
// The chicken-and-egg problem is solved by allocating the metaclass
// infrastructure with `class = NIL`, then patching every header.class
// once all ten objects exist.
//
// Bootstrap is one-shot. Refuses to run on a heap that has already been
// bootstrapped (whether in-process or loaded from a future image file).
// To start over: discard the heap and call Heap.init again.
pub fn bootstrap(heap: *Heap) !Globals {
    if (heap.isBootstrapped()) return error.AlreadyBootstrapped;

    var g: Globals = .{};

    // ---- Phase 1: allocate the kernel skeleton with class = NIL. ----
    //
    // Five regular classes:
    g.object_class = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    g.behavior_class = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    g.class_description_class = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    g.class_class = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    g.metaclass_class = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);

    // Five parallel metaclasses:
    const object_meta = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    const behavior_meta = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    const class_description_meta = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    const class_meta = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);
    const metaclass_meta = try heap.allocSlots(oop_mod.NIL, object.CLASS_INST_SIZE);

    // ---- Phase 2: patch header.class for the kernel. ----
    //
    // Each regular class's class is its metaclass; each metaclass's
    // class is Metaclass itself.
    object.headerOf(g.object_class).class = object_meta;
    object.headerOf(g.behavior_class).class = behavior_meta;
    object.headerOf(g.class_description_class).class = class_description_meta;
    object.headerOf(g.class_class).class = class_meta;
    object.headerOf(g.metaclass_class).class = metaclass_meta;

    object.headerOf(object_meta).class = g.metaclass_class;
    object.headerOf(behavior_meta).class = g.metaclass_class;
    object.headerOf(class_description_meta).class = g.metaclass_class;
    object.headerOf(class_meta).class = g.metaclass_class;
    object.headerOf(metaclass_meta).class = g.metaclass_class;

    // ---- Phase 3: wire up the regular-side hierarchy. ----
    //
    //   Object < nil
    //     Behavior < Object
    //       ClassDescription < Behavior
    //         Class < ClassDescription
    //         Metaclass < ClassDescription
    setKernelClass(g.object_class, oop_mod.NIL, 0);
    setKernelClass(g.behavior_class, g.object_class, 3);
    setKernelClass(g.class_description_class, g.behavior_class, 3);
    setKernelClass(g.class_class, g.class_description_class, object.CLASS_INST_SIZE);
    setKernelClass(g.metaclass_class, g.class_description_class, object.CLASS_INST_SIZE);

    // ---- Phase 4: wire up the parallel metaclass hierarchy. ----
    //
    // Standard rule: M class superclass == M superclass class, except
    // Object class superclass == Class (closes the loop).
    setKernelClass(object_meta, g.class_class, object.CLASS_INST_SIZE);
    setKernelClass(behavior_meta, object_meta, object.CLASS_INST_SIZE);
    setKernelClass(class_description_meta, behavior_meta, object.CLASS_INST_SIZE);
    setKernelClass(class_meta, class_description_meta, object.CLASS_INST_SIZE);
    setKernelClass(metaclass_meta, class_description_meta, object.CLASS_INST_SIZE);

    // Each metaclass's `thisClass` slot points back to its regular class.
    object.setSlot(object_meta, object.SLOT_THIS_CLASS, g.object_class);
    object.setSlot(behavior_meta, object.SLOT_THIS_CLASS, g.behavior_class);
    object.setSlot(class_description_meta, object.SLOT_THIS_CLASS, g.class_description_class);
    object.setSlot(class_meta, object.SLOT_THIS_CLASS, g.class_class);
    object.setSlot(metaclass_meta, object.SLOT_THIS_CLASS, g.metaclass_class);

    // ---- Phase 5: leaf classes (everything else). ----
    //
    // From here on we can use `defineClass` since Metaclass exists.
    g.undefined_class = try defineClass(heap, &g, g.object_class, 0);
    g.boolean_class = try defineClass(heap, &g, g.object_class, 0);
    g.true_class = try defineClass(heap, &g, g.boolean_class, 0);
    g.false_class = try defineClass(heap, &g, g.boolean_class, 0);
    g.smallinteger_class = try defineClass(heap, &g, g.object_class, 0);
    g.small_float_class = try defineClass(heap, &g, g.object_class, 0);
    g.large_positive_integer_class = try defineClass(heap, &g, g.object_class, 0);
    g.large_negative_integer_class = try defineClass(heap, &g, g.object_class, 0);
    g.byte_array_class = try defineClass(heap, &g, g.object_class, 0);
    g.string_class = try defineClass(heap, &g, g.byte_array_class, 0);
    g.symbol_class = try defineClass(heap, &g, g.string_class, 0);
    g.array_class = try defineClass(heap, &g, g.object_class, 0);
    g.dictionary_class = try defineClass(heap, &g, g.object_class, object.DICT_INST_SIZE);
    g.compiled_method_class = try defineClass(heap, &g, g.object_class, object.METHOD_INST_SIZE);
    // Frame is variable-sized (FRAME_VALUES_OFFSET + value_count per
    // activation); the class only needs to record zero ivar layout —
    // each invocation specifies its own size at allocSlots time.
    g.frame_class = try defineClass(heap, &g, g.object_class, 0);
    g.block_closure_class = try defineClass(heap, &g, g.object_class, object.BLOCK_INST_SIZE);
    g.literal_node_class = try defineClass(heap, &g, g.object_class, object.LIT_INST_SIZE);
    g.var_ref_node_class = try defineClass(heap, &g, g.object_class, object.VARREF_INST_SIZE);
    g.assign_node_class = try defineClass(heap, &g, g.object_class, object.ASSIGN_INST_SIZE);
    g.send_node_class = try defineClass(heap, &g, g.object_class, object.SEND_INST_SIZE);
    g.super_send_node_class = try defineClass(heap, &g, g.object_class, object.SUPER_INST_SIZE);
    g.block_node_class = try defineClass(heap, &g, g.object_class, object.BLOCKNODE_INST_SIZE);
    g.seq_node_class = try defineClass(heap, &g, g.object_class, object.SEQ_INST_SIZE);
    g.ret_node_class = try defineClass(heap, &g, g.object_class, object.RET_INST_SIZE);
    g.exception_class = try defineClass(heap, &g, g.object_class, object.EXCEPTION_INST_SIZE);

    // ---- Phase 5b: install the symbol intern table. ----
    //
    // Allocated now, before any setName/atPut, so every Symbol from
    // here on is interned. Symbols allocated up to this point (none —
    // we haven't called newSymbol yet) would have been raw.
    g.symbol_table = try dict_mod.newDictionary(heap, g.dictionary_class, g.array_class, object.INTERN_TABLE_CAPACITY);

    // Pre-intern frequently-used Symbols so eval.zig can compare Oops.
    g.sym_nil = try dict_mod.newSymbol(heap, &g, "nil");
    g.sym_true = try dict_mod.newSymbol(heap, &g, "true");
    g.sym_false = try dict_mod.newSymbol(heap, &g, "false");
    g.sym_smalltalk = try dict_mod.newSymbol(heap, &g, "Smalltalk");
    g.sym_thisContext = try dict_mod.newSymbol(heap, &g, "thisContext");
    g.sym_self = try dict_mod.newSymbol(heap, &g, "self");
    g.sym_value = try dict_mod.newSymbol(heap, &g, "value");
    g.sym_value_colon = try dict_mod.newSymbol(heap, &g, "value:");
    g.sym_plus = try dict_mod.newSymbol(heap, &g, "+");
    g.sym_minus = try dict_mod.newSymbol(heap, &g, "-");
    g.sym_times = try dict_mod.newSymbol(heap, &g, "*");
    g.sym_lt = try dict_mod.newSymbol(heap, &g, "<");
    g.sym_le = try dict_mod.newSymbol(heap, &g, "<=");
    g.sym_gt = try dict_mod.newSymbol(heap, &g, ">");
    g.sym_ge = try dict_mod.newSymbol(heap, &g, ">=");
    g.sym_printString = try dict_mod.newSymbol(heap, &g, "printString");
    g.sym_does_not_understand = try dict_mod.newSymbol(heap, &g, "doesNotUnderstand:");

    // ---- Phase 6: names. ----
    //
    // Now that Symbol class exists we can give every class a name.
    try setName(heap, &g, g.object_class, "Object");
    try setName(heap, &g, g.behavior_class, "Behavior");
    try setName(heap, &g, g.class_description_class, "ClassDescription");
    try setName(heap, &g, g.class_class, "Class");
    try setName(heap, &g, g.metaclass_class, "Metaclass");
    try setName(heap, &g, g.undefined_class, "UndefinedObject");
    try setName(heap, &g, g.boolean_class, "Boolean");
    try setName(heap, &g, g.true_class, "True");
    try setName(heap, &g, g.false_class, "False");
    try setName(heap, &g, g.smallinteger_class, "SmallInteger");
    try setName(heap, &g, g.small_float_class, "SmallFloat");
    try setName(heap, &g, g.large_positive_integer_class, "LargePositiveInteger");
    try setName(heap, &g, g.large_negative_integer_class, "LargeNegativeInteger");
    try setName(heap, &g, g.byte_array_class, "ByteArray");
    try setName(heap, &g, g.string_class, "String");
    try setName(heap, &g, g.symbol_class, "Symbol");
    try setName(heap, &g, g.array_class, "Array");
    try setName(heap, &g, g.dictionary_class, "Dictionary");
    try setName(heap, &g, g.compiled_method_class, "CompiledMethod");
    try setName(heap, &g, g.frame_class, "Frame");
    try setName(heap, &g, g.block_closure_class, "BlockClosure");
    try setName(heap, &g, g.literal_node_class, "LiteralNode");
    try setName(heap, &g, g.var_ref_node_class, "VarRefNode");
    try setName(heap, &g, g.assign_node_class, "AssignNode");
    try setName(heap, &g, g.send_node_class, "SendNode");
    try setName(heap, &g, g.super_send_node_class, "SuperSendNode");
    try setName(heap, &g, g.block_node_class, "BlockNode");
    try setName(heap, &g, g.seq_node_class, "SeqNode");
    try setName(heap, &g, g.ret_node_class, "RetNode");
    try setName(heap, &g, g.exception_class, "Exception");

    // Exception's single ivar so var_ref/assign find messageText. We
    // do this manually because defineClass doesn't take ivar names yet
    // for kernel classes.
    {
        const msg_sym = try dict_mod.newSymbol(heap, &g, "messageText");
        const ivar_arr = try heap.allocSlots(g.array_class, 1);
        object.setSlot(ivar_arr, 0, msg_sym);
        object.setSlot(g.exception_class, object.SLOT_CLASS_IVAR_NAMES, ivar_arr);
    }

    // ---- Phase 7: SystemDictionary. ----
    g.smalltalk = try dict_mod.newDictionary(heap, g.dictionary_class, g.array_class, object.SYSTEM_DICT_CAPACITY);
    try dictAtPut(heap, &g, g.smalltalk, "Object", g.object_class);
    try dictAtPut(heap, &g, g.smalltalk, "Behavior", g.behavior_class);
    try dictAtPut(heap, &g, g.smalltalk, "ClassDescription", g.class_description_class);
    try dictAtPut(heap, &g, g.smalltalk, "Class", g.class_class);
    try dictAtPut(heap, &g, g.smalltalk, "Metaclass", g.metaclass_class);
    try dictAtPut(heap, &g, g.smalltalk, "UndefinedObject", g.undefined_class);
    try dictAtPut(heap, &g, g.smalltalk, "Boolean", g.boolean_class);
    try dictAtPut(heap, &g, g.smalltalk, "True", g.true_class);
    try dictAtPut(heap, &g, g.smalltalk, "False", g.false_class);
    try dictAtPut(heap, &g, g.smalltalk, "SmallInteger", g.smallinteger_class);
    try dictAtPut(heap, &g, g.smalltalk, "SmallFloat", g.small_float_class);
    try dictAtPut(heap, &g, g.smalltalk, "LargePositiveInteger", g.large_positive_integer_class);
    try dictAtPut(heap, &g, g.smalltalk, "LargeNegativeInteger", g.large_negative_integer_class);
    try dictAtPut(heap, &g, g.smalltalk, "ByteArray", g.byte_array_class);
    try dictAtPut(heap, &g, g.smalltalk, "String", g.string_class);
    try dictAtPut(heap, &g, g.smalltalk, "Symbol", g.symbol_class);
    try dictAtPut(heap, &g, g.smalltalk, "Array", g.array_class);
    try dictAtPut(heap, &g, g.smalltalk, "Dictionary", g.dictionary_class);
    try dictAtPut(heap, &g, g.smalltalk, "CompiledMethod", g.compiled_method_class);
    try dictAtPut(heap, &g, g.smalltalk, "Frame", g.frame_class);
    try dictAtPut(heap, &g, g.smalltalk, "BlockClosure", g.block_closure_class);
    try dictAtPut(heap, &g, g.smalltalk, "LiteralNode", g.literal_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "VarRefNode", g.var_ref_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "AssignNode", g.assign_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "SendNode", g.send_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "SuperSendNode", g.super_send_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "BlockNode", g.block_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "SeqNode", g.seq_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "RetNode", g.ret_node_class);
    try dictAtPut(heap, &g, g.smalltalk, "Exception", g.exception_class);
    try dictAtPut(heap, &g, g.smalltalk, "Smalltalk", g.smalltalk);
    try dictAtPut(heap, &g, g.smalltalk, "SymbolTable", g.symbol_table);

    // ---- Phase 8: kernel primitives. ----
    try installPrim(heap, &g, g.smallinteger_class, "+", 1, prims.PRIM_INT_ADD);
    try installPrim(heap, &g, g.smallinteger_class, "-", 1, prims.PRIM_INT_SUB);
    try installPrim(heap, &g, g.smallinteger_class, "*", 1, prims.PRIM_INT_MUL);
    try installPrim(heap, &g, g.smallinteger_class, "<", 1, prims.PRIM_INT_LT);
    try installPrim(heap, &g, g.smallinteger_class, "//", 1, prims.PRIM_INT_DIV_FLOOR);
    try installPrim(heap, &g, g.smallinteger_class, "\\\\", 1, prims.PRIM_INT_MOD_FLOOR);
    try installPrim(heap, &g, g.smallinteger_class, "quo:", 1, prims.PRIM_INT_QUO);
    try installPrim(heap, &g, g.smallinteger_class, "rem:", 1, prims.PRIM_INT_REM);
    try installPrim(heap, &g, g.smallinteger_class, "asString", 0, prims.PRIM_INT_AS_STRING);
    try installPrim(heap, &g, g.smallinteger_class, "asFloat", 0, prims.PRIM_INT_AS_FLOAT);
    try installPrim(heap, &g, g.smallinteger_class, "=", 1, prims.PRIM_INT_EQ);
    inline for (.{ g.large_positive_integer_class, g.large_negative_integer_class }) |cls| {
        try installPrim(heap, &g, cls, "+", 1, prims.PRIM_LARGE_ADD);
        try installPrim(heap, &g, cls, "-", 1, prims.PRIM_LARGE_SUB);
        try installPrim(heap, &g, cls, "*", 1, prims.PRIM_LARGE_MUL);
        try installPrim(heap, &g, cls, "<", 1, prims.PRIM_LARGE_LT);
        try installPrim(heap, &g, cls, "<=", 1, prims.PRIM_LARGE_LE);
        try installPrim(heap, &g, cls, ">", 1, prims.PRIM_LARGE_GT);
        try installPrim(heap, &g, cls, ">=", 1, prims.PRIM_LARGE_GE);
        try installPrim(heap, &g, cls, "=", 1, prims.PRIM_LARGE_EQ);
        try installPrim(heap, &g, cls, "asString", 0, prims.PRIM_LARGE_AS_STRING);
        try installPrim(heap, &g, cls, "asFloat", 0, prims.PRIM_LARGE_AS_FLOAT);
    }
    try installPrim(heap, &g, g.small_float_class, "+", 1, prims.PRIM_FLOAT_ADD);
    try installPrim(heap, &g, g.small_float_class, "-", 1, prims.PRIM_FLOAT_SUB);
    try installPrim(heap, &g, g.small_float_class, "*", 1, prims.PRIM_FLOAT_MUL);
    try installPrim(heap, &g, g.small_float_class, "/", 1, prims.PRIM_FLOAT_DIV);
    try installPrim(heap, &g, g.small_float_class, "<", 1, prims.PRIM_FLOAT_LT);
    try installPrim(heap, &g, g.small_float_class, "<=", 1, prims.PRIM_FLOAT_LE);
    try installPrim(heap, &g, g.small_float_class, ">", 1, prims.PRIM_FLOAT_GT);
    try installPrim(heap, &g, g.small_float_class, ">=", 1, prims.PRIM_FLOAT_GE);
    try installPrim(heap, &g, g.small_float_class, "=", 1, prims.PRIM_FLOAT_EQ);
    try installPrim(heap, &g, g.small_float_class, "asString", 0, prims.PRIM_FLOAT_AS_STRING);
    try installPrim(heap, &g, g.small_float_class, "truncated", 0, prims.PRIM_FLOAT_TRUNCATED);
    try installPrim(heap, &g, g.small_float_class, "sqrt", 0, prims.PRIM_FLOAT_SQRT);
    try installPrim(heap, &g, g.small_float_class, "sin", 0, prims.PRIM_FLOAT_SIN);
    try installPrim(heap, &g, g.small_float_class, "cos", 0, prims.PRIM_FLOAT_COS);
    try installPrim(heap, &g, g.small_float_class, "ln", 0, prims.PRIM_FLOAT_LN);
    try installPrim(heap, &g, g.small_float_class, "exp", 0, prims.PRIM_FLOAT_EXP);
    try installPrim(heap, &g, g.class_class, "name", 0, prims.PRIM_BEHAVIOR_NAME);
    try installPrim(heap, &g, g.object_class, "printNl", 0, prims.PRIM_OBJ_PRINT_NL);
    try installPrim(heap, &g, g.object_class, "class", 0, prims.PRIM_OBJ_CLASS);
    try installPrim(heap, &g, g.object_class, "==", 1, prims.PRIM_OBJ_IDENTITY_EQ);
    // `=` defaults to identity at the Object level; subclasses that have
    // value semantics (String, Array...) override later.
    try installPrim(heap, &g, g.object_class, "=", 1, prims.PRIM_OBJ_IDENTITY_EQ);
    try installPrim(heap, &g, g.object_class, "become:", 1, prims.PRIM_OBJ_BECOME);
    try installPrim(heap, &g, g.object_class, "isKindOf:", 1, prims.PRIM_OBJ_IS_KIND_OF);
    try installPrim(heap, &g, g.object_class, "isMemberOf:", 1, prims.PRIM_OBJ_IS_MEMBER_OF);
    try installPrim(heap, &g, g.object_class, "instVarAt:", 1, prims.PRIM_OBJ_INST_VAR_AT);
    try installPrim(heap, &g, g.object_class, "instVarAt:put:", 2, prims.PRIM_OBJ_INST_VAR_AT_PUT);
    try installPrim(heap, &g, g.behavior_class, "instVarNames", 0, prims.PRIM_BEHAVIOR_INST_VAR_NAMES);
    try installPrim(heap, &g, g.object_class, "perform:", 1, prims.PRIM_OBJ_PERFORM);
    try installPrim(heap, &g, g.object_class, "asJson", 0, prims.PRIM_OBJ_AS_JSON);
    try installPrim(heap, &g, g.string_class, "asJsonValue", 0, prims.PRIM_STR_AS_JSON_VALUE);
    try installPrim(heap, &g, g.string_class, "findString:", 1, prims.PRIM_STRING_INDEX_OF);
    try installPrim(heap, &g, g.string_class, "subStrings:", 1, prims.PRIM_STRING_SUBSTRINGS);
    try installPrim(heap, &g, g.string_class, "asUppercase", 0, prims.PRIM_STRING_AS_UPPERCASE);
    try installPrim(heap, &g, g.string_class, "asLowercase", 0, prims.PRIM_STRING_AS_LOWERCASE);
    try installPrim(heap, &g, g.string_class, "replaceAll:with:", 2, prims.PRIM_STRING_REPLACE_ALL);
    try installPrim(heap, &g, g.string_class, "trimmed", 0, prims.PRIM_STRING_TRIMMED);
    try installPrim(heap, &g, g.string_class, "endsWith:", 1, prims.PRIM_STRING_ENDS_WITH);
    try installPrim(heap, &g, g.string_class, "asInteger", 0, prims.PRIM_STRING_AS_INTEGER);
    try installPrim(heap, &g, g.class_class, "selectors", 0, prims.PRIM_BEHAVIOR_SELECTORS);
    try installPrim(heap, &g, g.string_class, "startsWith:", 1, prims.PRIM_STRING_STARTS_WITH);
    try installPrim(heap, &g, g.exception_class, "signal:", 1, prims.PRIM_EXC_SIGNAL);
    try installPrim(heap, &g, g.exception_class, "messageText", 0, prims.PRIM_EXC_MESSAGE_TEXT);
    try installPrim(heap, &g, g.exception_class, "pass", 0, prims.PRIM_EXC_PASS);
    try installPrim(heap, &g, g.exception_class, "resignalAs:", 1, prims.PRIM_EXC_RESIGNAL_AS);
    try installPrim(heap, &g, g.block_closure_class, "ifCurtailed:", 1, prims.PRIM_BLOCK_IF_CURTAILED);
    try installPrim(heap, &g, g.block_closure_class, "on:do:", 2, prims.PRIM_BLOCK_ON_DO);
    try installPrim(heap, &g, g.block_closure_class, "ensure:", 1, prims.PRIM_BLOCK_ENSURE);
    try installPrim(heap, &g, g.block_closure_class, "value", 0, prims.PRIM_BLOCK_VALUE);
    try installPrim(heap, &g, g.block_closure_class, "value:", 1, prims.PRIM_BLOCK_VALUE_1);
    try installPrim(heap, &g, g.block_closure_class, "value:value:", 2, prims.PRIM_BLOCK_VALUE_2);
    try installPrim(heap, &g, g.block_closure_class, "value:value:value:", 3, prims.PRIM_BLOCK_VALUE_3);
    try installPrim(heap, &g, g.block_closure_class, "value:value:value:value:", 4, prims.PRIM_BLOCK_VALUE_4);
    try installPrim(heap, &g, g.block_closure_class, "whileTrue:", 1, prims.PRIM_BLOCK_WHILE_TRUE);
    try installPrim(heap, &g, g.block_closure_class, "whileFalse:", 1, prims.PRIM_BLOCK_WHILE_FALSE);
    try installPrim(heap, &g, g.true_class, "ifTrue:", 1, prims.PRIM_TRUE_IF_TRUE);
    try installPrim(heap, &g, g.true_class, "ifFalse:", 1, prims.PRIM_TRUE_IF_FALSE);
    try installPrim(heap, &g, g.true_class, "ifTrue:ifFalse:", 2, prims.PRIM_TRUE_IF_TRUE_IF_FALSE);
    try installPrim(heap, &g, g.false_class, "ifTrue:", 1, prims.PRIM_FALSE_IF_TRUE);
    try installPrim(heap, &g, g.false_class, "ifFalse:", 1, prims.PRIM_FALSE_IF_FALSE);
    try installPrim(heap, &g, g.false_class, "ifTrue:ifFalse:", 2, prims.PRIM_FALSE_IF_TRUE_IF_FALSE);
    try installPrim(heap, &g, g.class_class, "new", 0, prims.PRIM_CLASS_NEW);
    try installPrim(heap, &g, g.object_class, "size", 0, prims.PRIM_OBJECT_SIZE);
    try installPrim(heap, &g, g.array_class, "at:", 1, prims.PRIM_ARRAY_AT);
    try installPrim(heap, &g, g.array_class, "at:put:", 2, prims.PRIM_ARRAY_AT_PUT);
    // Array new: 5  →  install on Array's metaclass.
    const array_meta = object.headerOf(g.array_class).class;
    try installPrim(heap, &g, array_meta, "new:", 1, prims.PRIM_ARRAY_NEW_SIZED);
    try installPrim(heap, &g, g.string_class, ",", 1, prims.PRIM_STRING_CONCAT);
    try installPrim(heap, &g, g.string_class, "=", 1, prims.PRIM_STRING_EQUALS);
    try installPrim(heap, &g, g.string_class, "at:", 1, prims.PRIM_STRING_AT);
    try installPrim(heap, &g, g.string_class, "asSymbol", 0, prims.PRIM_STRING_AS_SYMBOL);
    try installPrim(heap, &g, g.symbol_class, "asString", 0, prims.PRIM_SYMBOL_AS_STRING);
    // String class>>fromCharCode: lives on String's metaclass.
    {
        const str_meta = object.headerOf(g.string_class).class;
        try installPrim(heap, &g, str_meta, "fromCharCode:", 1, prims.PRIM_STRING_FROM_CHAR_CODE);
    }
    try installPrim(heap, &g, g.smallinteger_class, "<=", 1, prims.PRIM_INT_LE);
    try installPrim(heap, &g, g.smallinteger_class, ">", 1, prims.PRIM_INT_GT);
    try installPrim(heap, &g, g.smallinteger_class, ">=", 1, prims.PRIM_INT_GE);

    // ---- Phase 9: stdlib (SUnit-lite). ----
    //
    // Lives in the heap like everything else; identical to a user
    // typing the definitions over the protocol.
    const stdlib_mod = @import("stdlib.zig");
    try stdlib_mod.loadSUnit(heap, &g);

    // ---- Phase 10: concurrency (Process / Semaphore / Processor). ----
    //
    // Surface ships now; cooperative scheduler with native stack
    // switching follows in subsequent commits.
    try stdlib_mod.loadConcurrency(heap, &g);
    try installPrim(heap, &g, g.block_closure_class, "fork", 0, prims.PRIM_BLOCK_FORK);
    try installPrim(heap, &g, g.block_closure_class, "forkAt:", 1, prims.PRIM_BLOCK_FORK_AT);
    try installPrim(heap, &g, g.semaphore_class, "wait", 0, prims.PRIM_SEMAPHORE_WAIT);
    try installPrim(heap, &g, g.semaphore_class, "signal", 0, prims.PRIM_SEMAPHORE_SIGNAL);
    try installPrim(heap, &g, g.process_class, "resume", 0, prims.PRIM_PROCESS_RESUME);
    try installPrim(heap, &g, g.process_class, "suspend", 0, prims.PRIM_PROCESS_SUSPEND);
    try installPrim(heap, &g, g.process_class, "terminate", 0, prims.PRIM_PROCESS_TERMINATE);
    try installPrim(heap, &g, g.scheduler_class, "yield", 0, prims.PRIM_PROCESSOR_YIELD);
    try installPrim(heap, &g, g.scheduler_class, "activeProcess", 0, prims.PRIM_PROCESSOR_ACTIVE);

    // Time class>>monotonicNanos and Delay>>wait — both surfaced
    // by stdlib's loadConcurrency, primitives installed here.
    const time_cls = dict_mod.lookup(g.smalltalk, "Time");
    if (oop_mod.isHeapPtr(time_cls)) {
        const time_meta = object.headerOf(time_cls).class;
        try installPrim(heap, &g, time_meta, "monotonicNanos", 0, prims.PRIM_TIME_MONO_NANOS);
    }
    const delay_cls = dict_mod.lookup(g.smalltalk, "Delay");
    if (oop_mod.isHeapPtr(delay_cls)) {
        try installPrim(heap, &g, delay_cls, "wait", 0, prims.PRIM_DELAY_WAIT);
    }

    // FileStream primitives. Receiver is a FileStream; slot 0 (`fd`)
    // is the underlying POSIX file descriptor.
    if (oop_mod.isHeapPtr(g.file_stream_class)) {
        try installPrim(heap, &g, g.file_stream_class, "primOpenPath:mode:", 2, prims.PRIM_FS_OPEN);
        try installPrim(heap, &g, g.file_stream_class, "read:", 1, prims.PRIM_FS_READ);
        try installPrim(heap, &g, g.file_stream_class, "readAll", 0, prims.PRIM_FS_READ_ALL);
        try installPrim(heap, &g, g.file_stream_class, "nextPutAll:", 1, prims.PRIM_FS_WRITE);
        try installPrim(heap, &g, g.file_stream_class, "primClose", 0, prims.PRIM_FS_CLOSE);
    }

    // Socket primitives. Same fd-at-slot-0 convention so the
    // read/write/close primitives reuse the FileStream prim
    // functions; only connect/listen/accept are net-specific.
    if (oop_mod.isHeapPtr(g.socket_class)) {
        try installPrim(heap, &g, g.socket_class, "primConnect:port:", 2, prims.PRIM_SOCK_CONNECT);
        try installPrim(heap, &g, g.socket_class, "primListen:", 1, prims.PRIM_SOCK_LISTEN);
        try installPrim(heap, &g, g.socket_class, "accept", 0, prims.PRIM_SOCK_ACCEPT);
        try installPrim(heap, &g, g.socket_class, "read:", 1, prims.PRIM_FS_READ);
        try installPrim(heap, &g, g.socket_class, "readAll", 0, prims.PRIM_FS_READ_ALL);
        try installPrim(heap, &g, g.socket_class, "nextPutAll:", 1, prims.PRIM_FS_WRITE);
        try installPrim(heap, &g, g.socket_class, "primClose", 0, prims.PRIM_FS_CLOSE);
    }

    // Seal the image header so a second bootstrap attempt fails fast,
    // and a future image loader can find Smalltalk without scanning.
    const hdr = heap.imageHeader();
    hdr.smalltalk = g.smalltalk;
    hdr.flags |= heap_mod.FLAG_BOOTSTRAPPED;

    return g;
}

// Fills the Behavior-shaped slots (superclass, methodDict=nil, instVarCount).
// The class's own class field is set separately by the bootstrap caller.
fn setKernelClass(cls: Oop, super: Oop, inst_var_count: u32) void {
    object.setSlot(cls, object.SLOT_SUPERCLASS, super);
    object.setSlot(cls, object.SLOT_METHOD_DICT, oop_mod.NIL);
    object.setSlot(cls, object.SLOT_INST_VAR_COUNT, oop_mod.fromInt(@intCast(inst_var_count)));
}

// Allocates a (regular class, metaclass) pair under an existing superclass.
// Used for every leaf class after the kernel is wired.
fn defineClass(heap: *Heap, g: *Globals, super: Oop, inst_var_count: u32) !Oop {
    const meta = try heap.allocSlots(g.metaclass_class, object.CLASS_INST_SIZE);
    const cls = try heap.allocSlots(meta, object.CLASS_INST_SIZE);

    // Regular side.
    object.setSlot(cls, object.SLOT_SUPERCLASS, super);
    object.setSlot(cls, object.SLOT_METHOD_DICT, oop_mod.NIL);
    object.setSlot(cls, object.SLOT_INST_VAR_COUNT, oop_mod.fromInt(@intCast(inst_var_count)));

    // Metaclass side: super is the parent's metaclass (or Class for Object's).
    const super_meta = if (oop_mod.isNil(super))
        g.class_class
    else
        object.headerOf(super).class;
    object.setSlot(meta, object.SLOT_SUPERCLASS, super_meta);
    object.setSlot(meta, object.SLOT_METHOD_DICT, oop_mod.NIL);
    object.setSlot(meta, object.SLOT_INST_VAR_COUNT, oop_mod.fromInt(@intCast(object.CLASS_INST_SIZE)));
    object.setSlot(meta, object.SLOT_THIS_CLASS, cls);

    return cls;
}

fn setName(heap: *Heap, g: *Globals, cls: Oop, name: []const u8) !void {
    const sym = try dict_mod.newSymbol(heap, g, name);
    object.setSlot(cls, object.SLOT_NAME, sym);
}

fn dictAtPut(heap: *Heap, g: *Globals, d: Oop, key: []const u8, value: Oop) !void {
    _ = try dict_mod.atPut(heap, d, g, key, value);
}

fn installPrim(heap: *Heap, g: *Globals, cls: Oop, selector: []const u8, arg_count: u32, prim_id: u32) !void {
    const m = try method_mod.newPrimitive(heap, g, cls, selector, arg_count, prim_id);
    try method_mod.install(heap, g, null, cls, selector, m);
}

test "bootstrap is one-shot" {
    var heap = try Heap.init(1 * 1024 * 1024);
    defer heap.deinit();

    const g1 = try bootstrap(&heap);
    try std.testing.expect(!oop_mod.isNil(g1.smalltalk));
    try std.testing.expect(heap.isBootstrapped());

    const result = bootstrap(&heap);
    try std.testing.expectError(error.AlreadyBootstrapped, result);
}

test "image header is initialized at offset 0" {
    var heap = try Heap.init(1 * 1024 * 1024);
    defer heap.deinit();

    const hdr = heap.imageHeader();
    try std.testing.expectEqual(heap_mod.IMAGE_MAGIC, hdr.magic);
    try std.testing.expectEqual(heap_mod.KERNEL_VERSION, hdr.version);
    try std.testing.expect(!heap.isBootstrapped());

    _ = try bootstrap(&heap);
    try std.testing.expect(heap.isBootstrapped());
    try std.testing.expect(!oop_mod.isNil(hdr.smalltalk));
}

