// Cs2Rb - translate the generated C# SWMM6 engine (cs/gen and cs/runtime/Hand_*.cs) into one Ruby file
// (ruby/gen/engine.rb), using Roslyn's semantic model, the way Cs2Py writes the Python engine. The design is
// recorded in RB.md; the runtime contract the file relies on is the Python port's (py/RUNTIME_HELPERS.md), with
// the Ruby spellings RB.md lists.
//
//   dotnet bin/cs2rb.dll CS_DIR RB_GEN_DIR
//
// writes RB_GEN_DIR/engine.rb, RB_GEN_DIR/../cs2rb_runtime.txt (every runtime name the file uses, with the C#
// member it stands for) and RB_GEN_DIR/../cs2rb_todo.txt (untranslated constructs; the goal is none).
//
// Begun from tools/cs2x/Cs2Py.cs (the analysis and the names are the Python back end's; the printing is Ruby's).
// Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and ruby/README.md.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public sealed class Todo : Exception { public Todo(string m) : base(m) { } }

public static partial class Cs2Rb
{
    static CSharpCompilation comp = null!;
    static readonly Dictionary<SyntaxTree, SemanticModel> models = new();
    static SemanticModel M(SyntaxNode n) => models[n.SyntaxTree];
    static readonly SortedDictionary<string, int> todos = new();
    /// <summary>Ruby runtime name -> the C# member(s) it stands for (the manifest).</summary>
    static readonly SortedDictionary<string, SortedSet<string>> manifest = new(StringComparer.Ordinal);
    static readonly SortedDictionary<string, int> stats = new();

    public static int Main(string[] args)
    {
        var cs = args[0];
        var outDir = args[1];
        var files = Directory.GetFiles(Path.Combine(cs, "gen"), "*.cs").Concat(Directory.GetFiles(Path.Combine(cs, "runtime"), "*.cs"))
            .Where(f => !f.EndsWith("Program.cs")).OrderBy(f => f, StringComparer.Ordinal).ToArray();
        var opts = new CSharpParseOptions(LanguageVersion.Latest);
        var trees = files.Select(f => CSharpSyntaxTree.ParseText(File.ReadAllText(f), opts, f)).ToList();
        var fw = Path.GetDirectoryName(typeof(object).Assembly.Location)!;
        var refs = new List<MetadataReference>();
        foreach (var f in Directory.GetFiles(fw, "*.dll"))
        {
            var b = Path.GetFileName(f);
            if (b.StartsWith("Microsoft.VisualBasic") || b == "mscorlib.dll") continue;
            try { refs.Add(MetadataReference.CreateFromFile(f)); } catch { }
        }
        comp = CSharpCompilation.Create("engine", trees, refs, new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary, allowUnsafe: true));
        var errs = comp.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        if (errs.Count > 0) { foreach (var e in errs.Take(10)) Console.Error.WriteLine(e); return 1; }
        foreach (var t in trees) models[t] = comp.GetSemanticModel(t);
        // the engine: the generated C#, and the hand-written engine parts kept with the runtime (Hand_*.cs)
        var gen = trees.Where(t => t.FilePath.Contains("/gen/") || Path.GetFileName(t.FilePath).StartsWith("Hand_")).ToList();

        Directory.CreateDirectory(outDir);
        CollectTypes(gen);
        CollectRuntimeNames();
        Analyze(gen);
        var text = Module(gen);
        CheckNameClashes();
        File.WriteAllText(Path.Combine(outDir, "engine.rb"), text);
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2rb_todo.txt")))
            foreach (var kv in todos.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteLine("{0,6}  {1}", kv.Value, kv.Key);
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2rb_runtime.txt")))
        {
            w.WriteLine("# The runtime names ruby/gen/engine.rb uses: Ruby name, tab, the C# member(s) it stands for (a .name is a member of runtime objects, a Cpp:: name a class or module of the runtime). See tools/cs2x/RB.md.");
            w.WriteLine("# Written by tools/cs2x/Cs2Rb.cs. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.");
            foreach (var kv in manifest) w.WriteLine(kv.Key + "\t" + string.Join(" | ", kv.Value));
        }
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2rb_stats.txt")))
            foreach (var kv in stats.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteLine("{0,7}  {1}", kv.Value, kv.Key);
        Console.WriteLine("wrote engine.rb (" + text.Count(c => c == '\n') + " lines), " + manifest.Count + " runtime names, " + todos.Count + " TODO kinds, " + todos.Values.Sum() + " TODO sites");
        return 0;
    }

    static void Note(string what) { todos[what] = todos.TryGetValue(what, out var c) ? c + 1 : 1; }
    static void Stat(string what) { stats[what] = stats.TryGetValue(what, out var c) ? c + 1 : 1; }

    static string Todo(string what)
    {
        todos[what] = todos.TryGetValue(what, out var c) ? c + 1 : 1;
        throw new Todo(what);
    }

    /// <summary>Record that the engine uses runtime name rb (a function of module Cpp, which the runner includes
    /// into Object, or a constant or class of Cpp) for the C# member cs; returns rb.</summary>
    static string Use(string rb, string cs)
    {
        if (!manifest.TryGetValue(rb, out var set)) manifest[rb] = set = new SortedSet<string>(StringComparer.Ordinal);
        set.Add(cs);
        return rb;
    }

    /// <summary>Record that the engine uses member rb (a method or attribute of runtime objects) for the C# member
    /// cs; returns rb. The manifest lists these as .rb.</summary>
    static string UseM(string rb, string cs)
    {
        var k = "." + rb;
        if (!manifest.TryGetValue(k, out var set)) manifest[k] = set = new SortedSet<string>(StringComparer.Ordinal);
        set.Add(cs);
        return rb;
    }

    /// <summary>A runtime class or module, referred to through its namespace (Cpp::Vec): Ruby's own top-level
    /// constants include Set, Thread, Mutex and Queue, which an unqualified name could reach first.</summary>
    static string UseC(string rb, string cs) => "Cpp::" + Use("Cpp::" + rb, cs).Substring(5);

    /// <summary>The helper functions the translator writes calls to (the runtime defines them; RB.md).</summary>
    static readonly HashSet<string> HelperNames = new()
    {
        "GotoSignal", "SysException", "f64_from_bits", "f64_to_bits_signed", "signbit",
        "cs_tostring", "cs_equals", "cs_chr", "exc_message", "idiv", "irem", "fmod", "fdiv0", "f32", "f2i32", "f2u32", "f2i64",
        "f2u64", "f2i16", "f2u16", "f2i8", "f2u8", "U32", "U64", "I64", "U8", "I8", "I16", "U16", "Ch", "F32",
        "MK_Z", "MK_D", "MK_I", "MK_N", "Array_Fill", "File_Exists", "Math_Sqrt_d"
    };

    // ------------------------------------------------------------------------------------------------ names
    /// <summary>Ruby's reserved words: no local, method or attribute may be spelled as one.</summary>
    static readonly HashSet<string> RbKeywords = new()
    {
        "BEGIN", "END", "__ENCODING__", "__END__", "__FILE__", "__LINE__", "alias", "and", "begin", "break", "case",
        "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next",
        "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
        "until", "when", "while", "yield", "it", "_1", "_2", "_3", "_4", "_5", "_6", "_7", "_8", "_9"
    };

    /// <summary>The methods every Ruby object has (Object, Kernel, BasicObject, as Ruby 3.3.6 lists them, and
    /// Exception's for the one engine exception class), and the runtime's helpers: an engine method or attribute
    /// spelled as one would replace it, so it gets a trailing _.</summary>
    static readonly HashSet<string> RbObjectMethods = new()
    {
        "Array", "Complex", "Float", "Hash", "Integer", "Rational", "String", "__callee__", "__dir__", "__id__",
        "__method__", "__send__", "abort", "at_exit", "autoload", "binding", "caller", "caller_locations", "catch",
        "class", "clone", "define_singleton_method", "display", "dup", "enum_for", "eval", "exec", "exit", "extend",
        "fail", "fork", "format", "freeze", "gem", "gem_original_require", "gets", "global_variables", "hash",
        "initialize", "initialize_clone", "initialize_copy", "initialize_dup", "inspect", "instance_eval",
        "instance_exec", "instance_variable_get", "instance_variable_set", "instance_variables", "itself", "lambda",
        "load", "local_variables", "loop", "method", "method_missing", "methods", "object_id", "open", "p", "pp", "print",
        "printf", "private_methods", "proc", "protected_methods", "public_method", "public_methods", "public_send",
        "putc", "puts", "raise", "rand", "readline", "readlines", "remove_instance_variable", "require",
        "require_relative", "select", "send", "set_trace_func", "singleton_class", "singleton_method",
        "singleton_method_added", "singleton_method_removed", "singleton_method_undefined", "singleton_methods",
        "sleep", "spawn", "sprintf", "srand", "syscall", "system", "tap", "test", "then", "throw", "to_enum", "to_s",
        "trace_var", "trap", "untrace_var", "warn", "yield_self", "instance_of", "kind_of", "is_a", "nil", "equal",
        "eql", "frozen", "respond_to", "to_str", "to_ary", "to_proc", "to_hash", "to_a", "to_i", "to_f", "call",
        "message", "backtrace", "cause", "exception", "full_message", "detailed_message", "set_backtrace",
        "backtrace_locations"
    };

    /// <summary>An identifier: only letters, digits and _, not starting with a digit.</summary>
    static string RbIdent(string n)
    {
        n = n.TrimStart('@');
        var sb = new StringBuilder();
        foreach (var ch in n) sb.Append(ch < 128 && (char.IsLetterOrDigit(ch) || ch == '_') ? ch : '_');
        n = sb.ToString();
        if (n.Length == 0 || char.IsDigit(n[0])) n = "_" + n;
        return n;
    }

    /// <summary>A local variable or parameter: Ruby reads a capital first letter as a constant, so such a name
    /// gets a leading _ (the SWMM5 Ruby port's rule); a reserved word a trailing one.</summary>
    static string LocalIdent(string n)
    {
        n = RbIdent(n);
        if (char.IsUpper(n[0])) n = "_" + n;
        if (RbKeywords.Contains(n)) n += "_";
        return n;
    }

    /// <summary>An attribute (field) or method name: no reserved word, no method every object has, no helper
    /// the engine calls without a receiver.</summary>
    static string AttrIdent(string n)
    {
        n = RbIdent(n);
        while (RbKeywords.Contains(n) || RbObjectMethods.Contains(n) || HelperNames.Contains(n)) n += "_";
        return n;
    }

    /// <summary>The Python back end's name rule for identifiers that become parts of function names.</summary>
    static string PyIdent(string n)
    {
        n = n.TrimStart('@');
        var sb = new StringBuilder();
        foreach (var ch in n) sb.Append(char.IsLetterOrDigit(ch) || ch == '_' ? ch : '_');
        n = sb.ToString();
        if (n.Length == 0 || char.IsDigit(n[0])) n = "_" + n;
        return n;
    }

    static bool IsRuntime(ISymbol s)
    {
        var ns = s is INamespaceSymbol nss ? nss : s.ContainingNamespace;
        while (ns != null && !ns.IsGlobalNamespace)
        {
            if (ns.Name == "Cpp" && ns.ContainingNamespace.IsGlobalNamespace) return true;
            ns = ns.ContainingNamespace;
        }
        return false;
    }

    static bool IsSystem(ISymbol s)
    {
        var ns = s.ContainingNamespace;
        while (ns != null && !ns.IsGlobalNamespace) { if (ns.Name == "System" && ns.ContainingNamespace.IsGlobalNamespace) return true; ns = ns.ContainingNamespace; }
        return false;
    }

    // every top-level function the engine defines (static methods, factories, static initialisers), every engine
    // instance method and attribute: CheckNameClashes makes sure no call without a receiver can reach the wrong one
    static readonly HashSet<string> engineFunctions = new();
    static readonly HashSet<string> engineMembers = new();
    static readonly HashSet<string> runtimeTypeNames = new();

    static void CollectRuntimeNames()
    {
        void Walk(INamespaceOrTypeSymbol ns)
        {
            foreach (var m in ns.GetMembers())
            {
                if (m is INamedTypeSymbol t)
                {
                    var parts = new List<string>();
                    for (var c = t; c != null; c = c.ContainingType) parts.Insert(0, StripArity(c.Name));
                    var b = string.Join("_", parts);
                    runtimeTypeNames.Add(b);
                    foreach (var code in new[] { "D", "F", "I", "L", "B", "Z", "S", "C" }) runtimeTypeNames.Add(b + code);
                    Walk(t);
                }
                else if (m is INamespaceSymbol n) Walk(n);
            }
        }
        foreach (var ns in comp.GlobalNamespace.GetNamespaceMembers().Where(n => n.Name == "Cpp")) Walk(ns);
    }

    /// <summary>An engine instance method or attribute must not share its name with a function called without a
    /// receiver (an engine function or a runtime function): inside that class the call would reach the method.</summary>
    static void CheckNameClashes()
    {
        foreach (var m in engineMembers)
        {
            if (engineFunctions.Contains(m)) Note("an engine member is spelled as an engine function: " + m);
            if (manifest.ContainsKey(m) && !m.StartsWith(".")) Note("an engine member is spelled as a runtime function: " + m);
        }
    }

    static readonly Dictionary<ISymbol, string> typeNames = new(SymbolEqualityComparer.Default);
    static readonly Dictionary<ISymbol, string> classConsts = new(SymbolEqualityComparer.Default);
    static readonly HashSet<string> usedClassConsts = new();

    /// <summary>The Python back end's name of an engine type (its namespace below openswmm and its class nesting,
    /// joined by _; a namespace's free functions class _F is F_, F_ns): the prefix of its functions and globals.</summary>
    static string TypeIdent(INamedTypeSymbol t)
    {
        t = t.OriginalDefinition;
        if (typeNames.TryGetValue(t, out var n)) return n;
        var parts = new List<string>();
        for (var c = t; c != null; c = c.ContainingType) parts.Insert(0, c.Name);
        var ns = new List<string>();
        for (var x = t.ContainingNamespace; x != null && !x.IsGlobalNamespace; x = x.ContainingNamespace) ns.Insert(0, x.Name);
        if (ns.Count > 0 && (ns[0] == "openswmm" || ns[0] == "_global" || ns[0] == "Gen")) ns.RemoveAt(0);
        var s = PyIdent(string.Join("_", ns.Concat(parts)));
        if (t.Name == "_F" && t.ContainingType == null)
        {
            var full = new List<string>();
            for (var x = t.ContainingNamespace; x != null && !x.IsGlobalNamespace; x = x.ContainingNamespace) full.Insert(0, x.Name);
            s = full.Count == 1 && full[0] == "openswmm" ? "F" : full.Count > 0 && full[0] == "openswmm" ? "F_" + string.Join("_", full.Skip(1)) : "F_" + string.Join("_", full);
        }
        while (runtimeTypeNames.Contains(s) || s.StartsWith("__")) s += "_";
        typeNames[t] = s;
        return s;
    }

    /// <summary>Ruby's constant for an engine class: the type's name with a capital first letter (Ruby reads a name
    /// as a constant only then), and a trailing _ when that would be one of Ruby's own top-level constants or
    /// another engine class's.</summary>
    static string ClassConst(INamedTypeSymbol t)
    {
        t = t.OriginalDefinition;
        if (classConsts.TryGetValue(t, out var n)) return n;
        var s = TypeIdent(t);
        if (s[0] == '_') s = "U" + s;
        s = char.ToUpperInvariant(s[0]) + s.Substring(1);
        while (RubyConstants.Contains(s) || usedClassConsts.Contains(s) || s.StartsWith("FR_") || s.StartsWith("SR_") || s.StartsWith("K_") || s.StartsWith("UM_")) s += "_";
        usedClassConsts.Add(s);
        classConsts[t] = s;
        return s;
    }

    /// <summary>Ruby 3.3.6's top-level constants (Object.constants), and the runtime's module.</summary>
    static readonly HashSet<string> RubyConstants = new()
    {
        "ARGF", "ARGV", "ArgumentError", "Array", "BasicObject", "Binding", "CROSS_COMPILING", "Class", "ClosedQueueError",
        "Comparable", "Complex", "ConditionVariable", "Data", "DidYouMean", "Dir", "ENV", "EOFError", "Encoding",
        "EncodingError", "Enumerable", "Enumerator", "Errno", "ErrorHighlight", "Exception", "FalseClass", "Fiber",
        "FiberError", "File", "FileTest", "Float", "FloatDomainError", "FrozenError", "GC", "Gem", "Hash", "IO", "IOError",
        "IndexError", "Integer", "Interrupt", "Kernel", "KeyError", "LoadError", "LocalJumpError", "Marshal", "MatchData",
        "Math", "Method", "Module", "Monitor", "MonitorMixin", "Mutex", "NameError", "NilClass", "NoMatchingPatternError",
        "NoMatchingPatternKeyError", "NoMemoryError", "NoMethodError", "NotImplementedError", "Numeric", "Object",
        "ObjectSpace", "Proc", "Process", "Queue", "Ractor", "Random", "Range", "RangeError", "Rational", "RbConfig",
        "Refinement", "Regexp", "RegexpError", "RubyVM", "RuntimeError", "STDERR", "STDIN", "STDOUT", "ScriptError",
        "SecurityError", "Set", "Signal", "SignalException", "SizedQueue", "StandardError", "StopIteration", "String",
        "Struct", "Symbol", "SyntaxError", "SyntaxSuggest", "SystemCallError", "SystemExit", "SystemStackError",
        "TOPLEVEL_BINDING", "Thread", "ThreadError", "ThreadGroup", "Time", "TracePoint", "TrueClass", "TypeError",
        "UnboundMethod", "UncaughtThrowError", "UnicodeNormalize", "Warning", "ZeroDivisionError", "Cpp", "Fiddle",
        "Engine", "Main"
    };

    /// <summary>A static method's top-level function name: its type's name and the method's (as Go names them).</summary>
    static string StaticFuncName(IMethodSymbol m) => TypeIdent(m.ContainingType) + "_" + MethodIdent(m);

    /// <summary>A static field: a Ruby global variable.</summary>
    static string StaticFieldName(IFieldSymbol f) => "$" + TypeIdent(f.ContainingType) + "_" + PyIdent(f.Name);

    static readonly Dictionary<IMethodSymbol, string> methodNames = new(SymbolEqualityComparer.Default);

    /// <summary>An engine method's Ruby name. Every Ruby method call is virtual, so overloads in one class, and a
    /// method that overloads or hides (rather than overrides) one of a base class, get a suffix of their parameter
    /// types (Go's rule); a hiding method with the same parameters also gets its class's name; an override keeps
    /// the name of the method it overrides. A method that would share its name with a field anywhere in its
    /// hierarchy gets M_. A method implementing a runtime interface member keeps that member's name.</summary>
    static string MethodIdent(IMethodSymbol m)
    {
        m = m.OriginalDefinition;
        if (m.OverriddenMethod != null) return MethodIdent(m.OverriddenMethod);
        if (methodNames.TryGetValue(m, out var n)) return n;
        var t = m.ContainingType;
        var nm = AttrIdent(m.Name);
        var impl = !m.IsStatic ? RuntimeInterfaceMember(m) : null;
        if (impl != null) { methodNames[m] = impl; return impl; }
        var same = t.GetMembers(m.Name).OfType<IMethodSymbol>().Where(x => x.MethodKind == MethodKind.Ordinary).ToList();
        bool overloaded = same.Count > 1;
        bool hidesSame = false;
        if (!m.IsStatic)
        {
            for (var b = t.BaseType; b != null && !IsSystem(b) && !IsRuntime(b); b = b.BaseType)
                foreach (var x in b.GetMembers(m.Name).OfType<IMethodSymbol>())
                    if (x.MethodKind == MethodKind.Ordinary && !x.IsStatic && !IsOverrideOf(m, x))
                    { overloaded = true; if (SameParams(x, m)) hidesSame = true; }
        }
        if (overloaded)
            nm += "__" + string.Join("_", m.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : "")));
        if (hidesSame) nm += "__" + TypeIdent(t);
        if (!m.IsStatic && HierarchyHasField(t, nm)) nm = "M_" + nm;
        while (!m.IsStatic && (RbObjectMethods.Contains(nm) || HelperNames.Contains(nm))) nm += "_";
        methodNames[m] = nm;
        if (!m.IsStatic) engineMembers.Add(nm);
        return nm;
    }

    static bool SameParams(IMethodSymbol a, IMethodSymbol b) =>
        a.Parameters.Length == b.Parameters.Length && a.Parameters.Zip(b.Parameters).All(p => SymbolEqualityComparer.Default.Equals(p.First.Type, p.Second.Type) && p.First.RefKind == p.Second.RefKind);

    /// <summary>The runtime interface member (ICopy.Clone, IHashFn.HashOf, IBinFn.Call2, IDisposable.Dispose, ...)
    /// m implements, by name: the runtime calls it by that name.</summary>
    static string? RuntimeInterfaceMember(IMethodSymbol m)
    {
        foreach (var i in m.ContainingType.AllInterfaces)
        {
            if (!IsRuntime(i) && !IsSystem(i)) continue;
            foreach (var im in i.GetMembers().OfType<IMethodSymbol>())
            {
                var impl = m.ContainingType.FindImplementationForInterfaceMember(im);
                if (SymbolEqualityComparer.Default.Equals(impl?.OriginalDefinition, m)) return im.Name;
            }
        }
        return null;
    }

    static bool IsOverrideOf(IMethodSymbol m, IMethodSymbol b)
    {
        for (var o = m.OverriddenMethod; o != null; o = o.OverriddenMethod) if (SymbolEqualityComparer.Default.Equals(o.OriginalDefinition, b.OriginalDefinition)) return true;
        return false;
    }

    static bool Derives(INamedTypeSymbol d, INamedTypeSymbol b)
    {
        for (var x = d.BaseType; x != null; x = x.BaseType) if (SymbolEqualityComparer.Default.Equals(x.OriginalDefinition, b.OriginalDefinition)) return true;
        return false;
    }

    /// <summary>The root of t's engine class hierarchy.</summary>
    static INamedTypeSymbol RootOf(INamedTypeSymbol t)
    {
        var r = t.OriginalDefinition;
        while (r.BaseType != null && IsEngine(r.BaseType)) r = r.BaseType.OriginalDefinition;
        return r;
    }

    /// <summary>Whether any class of t's hierarchy (ancestors and descendants) has an instance field named nm.</summary>
    static bool HierarchyHasField(INamedTypeSymbol t, string nm)
    {
        var root = RootOf(t);
        foreach (var c in engineTypes)
        {
            if (!SymbolEqualityComparer.Default.Equals(RootOf(c), root)) continue;
            if (c.GetMembers().OfType<IFieldSymbol>().Any(f => !f.IsStatic && !f.IsConst && FieldIdent(f) == nm)) return true;
        }
        return false;
    }

    static string ShortType(ITypeSymbol t)
    {
        switch (t.SpecialType)
        {
            case SpecialType.System_Int32: return "i";
            case SpecialType.System_Int64: return "l";
            case SpecialType.System_UInt64: return "ul";
            case SpecialType.System_UInt32: return "u";
            case SpecialType.System_Double: return "d";
            case SpecialType.System_Single: return "f";
            case SpecialType.System_Boolean: return "b";
            case SpecialType.System_SByte: return "c";
            case SpecialType.System_Byte: return "uc";
            case SpecialType.System_Int16: return "s";
            case SpecialType.System_UInt16: return "us";
            case SpecialType.System_Char: return "ch";
            case SpecialType.System_Object: return "o";
            case SpecialType.System_String: return "str";
        }
        if (t is IArrayTypeSymbol at) return ShortType(at.ElementType) + "A";
        if (t is ITypeParameterSymbol tp) return tp.Name;
        if (t is INamedTypeSymbol nt)
        {
            var s = nt.Name;
            if (nt.TypeArguments.Length > 0) s += string.Join("", nt.TypeArguments.Select(ShortType));
            return s;
        }
        return "x";
    }

    static readonly Dictionary<IFieldSymbol, string> fieldNames = new(SymbolEqualityComparer.Default);

    /// <summary>An instance field's attribute name (and instance variable, @name). C# lets a derived class hide a
    /// base field with its own; Ruby's instance variables would merge them, so the hiding field gets its class's name.</summary>
    static string FieldIdent(IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (fieldNames.TryGetValue(f, out var n)) return n;
        n = AttrIdent(f.Name);
        if (!f.IsStatic && IsEngine(f.ContainingType))
            for (var b = f.ContainingType.BaseType; b != null && b.SpecialType != SpecialType.System_Object && !IsSystem(b); b = b.BaseType)
                if (b.GetMembers(f.Name).OfType<IFieldSymbol>().Any(x => !x.IsStatic)) { n += "_" + TypeIdent(f.ContainingType); Stat("hidden field (renamed) " + f.Name); break; }
        fieldNames[f] = n;
        if (!f.IsStatic && IsEngine(f.ContainingType)) engineMembers.Add(n);
        return n;
    }

    static string StripArity(string s) { var i = s.IndexOf('`'); return i < 0 ? s : s.Substring(0, i); }
}
