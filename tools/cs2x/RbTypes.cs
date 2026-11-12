// RbTypes.cs - C# types to Ruby, the cell analysis, and the declarations of the Ruby engine file.
// Begun from PyTypes.cs: the analysis is the Python back end's; the declarations are printed as Ruby.
// Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and ruby/README.md.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Rb
{
    static readonly List<INamedTypeSymbol> engineTypes = new();

    static bool IsEngine(ITypeSymbol t) => t is INamedTypeSymbol n && !IsRuntime(n) && !IsSystem(n) && n.Locations.Any(l => l.IsInSource);

    static void CollectTypes(List<SyntaxTree> gen)
    {
        var seen = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        foreach (var t in gen)
        {
            foreach (var td in t.GetRoot().DescendantNodes().OfType<BaseTypeDeclarationSyntax>())
            {
                var s = (INamedTypeSymbol)M(td).GetDeclaredSymbol(td)!;
                if (seen.Add(s)) engineTypes.Add(s);
            }
            foreach (var dd in t.GetRoot().DescendantNodes().OfType<DelegateDeclarationSyntax>())
            {
                var s = (INamedTypeSymbol)M(dd).GetDeclaredSymbol(dd)!;
                if (seen.Add(s)) engineTypes.Add(s);
            }
        }
        foreach (var s in engineTypes)
        {
            if (s.TypeKind is TypeKind.Enum or TypeKind.Delegate) continue;
            if (IsClassEmitted(s)) ClassConst(s);
            foreach (var m in s.GetMembers())
                if (m is IMethodSymbol ms && ms.IsStatic && ms.MethodKind == MethodKind.Ordinary) engineFunctions.Add(StaticFuncName(ms));
            engineFunctions.Add(TypeIdent(s) + "__new");
        }
        foreach (var g in engineTypes.Where(IsClassEmitted).GroupBy(TypeIdent).Where(g => g.Count() > 1)) Note("two types named " + g.Key);
    }

    /// <summary>A static class is no Ruby class: its members are top-level functions and global variables.</summary>
    static bool IsClassEmitted(INamedTypeSymbol s) => s.TypeKind == TypeKind.Class && !s.IsStatic;

    // ------------------------------------------------------------------------------------------------ cell analysis
    // A local or parameter is a cell (runtime Cpp::Cell, read x.v) when its address is taken (a ref or out argument, a
    // ref local, a ref return), or when it is declared inside a loop body (a fresh variable per iteration in C#),
    // captured by a lambda and assigned anywhere but its declaration: the lambda is made inside a function that takes
    // the iteration's cell. A captured loop-body variable that is never reassigned is bound by value the same way.
    static readonly HashSet<ISymbol> boxed = new(SymbolEqualityComparer.Default);
    static readonly HashSet<ISymbol> loopScoped = new(SymbolEqualityComparer.Default);
    static readonly HashSet<ISymbol> addrTaken = new(SymbolEqualityComparer.Default);
    /// <summary>Static fields whose address is taken (a range-for bound must not be one).</summary>
    static readonly HashSet<ISymbol> fieldAddr = new(SymbolEqualityComparer.Default);

    static void Analyze(List<SyntaxTree> gen)
    {
        var mutated = new HashSet<ISymbol>(SymbolEqualityComparer.Default);
        var captured = new HashSet<ISymbol>(SymbolEqualityComparer.Default);
        foreach (var t in gen)
        {
            var m = models[t];
            foreach (var node in t.GetRoot().DescendantNodes().Where(n => n is BaseMethodDeclarationSyntax || n is VariableDeclaratorSyntax && n.Parent?.Parent is FieldDeclarationSyntax))
            {
                IOperation? root = node switch
                {
                    BaseMethodDeclarationSyntax bm => bm.Body != null ? m.GetOperation(bm.Body) : bm.ExpressionBody != null ? m.GetOperation(bm.ExpressionBody) : null,
                    VariableDeclaratorSyntax vd => vd.Initializer != null ? m.GetOperation(vd.Initializer) : null,
                    _ => null
                };
                if (root == null) continue;
                if (node is ConstructorDeclarationSyntax cds && cds.Initializer != null && m.GetOperation(cds.Initializer) is IOperation ci) Scan(ci);
                Scan(root);
            }
        }
        void Scan(IOperation root)
        {
            foreach (var op in root.DescendantsAndSelf())
            {
                switch (op)
                {
                    case IArgumentOperation a when a.Parameter != null && (a.Parameter.RefKind == RefKind.Ref || a.Parameter.RefKind == RefKind.Out):
                        Mark(a.Value, addrTaken); break;
                    case IVariableDeclaratorOperation vd when vd.Symbol.RefKind != RefKind.None && vd.Initializer != null:
                        Mark(vd.Initializer.Value, addrTaken); break;
                    case IReturnOperation r when r.ReturnedValue != null && IsRefReturn(r):
                        Mark(r.ReturnedValue, addrTaken); break;
                    case ISimpleAssignmentOperation sa when sa.IsRef:
                        Mark(sa.Value, addrTaken); break;
                    case IConditionalOperation c when c.IsRef:
                        Mark(c.WhenTrue, addrTaken); if (c.WhenFalse != null) Mark(c.WhenFalse, addrTaken); break;
                    case IAssignmentOperation asg:
                        Mark(asg.Target, mutated); break;
                    case IIncrementOrDecrementOperation inc:
                        Mark(inc.Target, mutated); break;
                    case IVariableDeclaratorOperation vd2:
                        if (InLoopBody(vd2.Syntax)) loopScoped.Add(vd2.Symbol);
                        break;
                    case IForEachLoopOperation fe:
                        foreach (var l in fe.Locals) loopScoped.Add(l);
                        if (fe.LoopControlVariable is IVariableDeclaratorOperation fv) loopScoped.Add(fv.Symbol);
                        break;
                    case IAnonymousFunctionOperation af:
                        foreach (var r in af.Body.Descendants())
                        {
                            ISymbol? s = r is ILocalReferenceOperation lr ? lr.Local : r is IParameterReferenceOperation pr ? pr.Parameter : null;
                            if (s == null) continue;
                            if (!SymbolEqualityComparer.Default.Equals(s.ContainingSymbol, af.Symbol) && !IsInside(s.ContainingSymbol, af.Symbol)) captured.Add(s);
                        }
                        break;
                }
                if (op is IFieldReferenceOperation fr && IsAddrUse(fr)) fieldAddr.Add(fr.Field.OriginalDefinition);
            }
        }
        foreach (var s in addrTaken) if (!IsRefSym(s)) boxed.Add(s);
        foreach (var s in captured) if (loopScoped.Contains(s) && (mutated.Contains(s) || addrTaken.Contains(s)) && !IsRefSym(s)) boxed.Add(s);
    }

    static bool IsAddrUse(IOperation op)
    {
        var p = op.Parent;
        while (p is IConversionOperation cv && cv.Conversion.IsIdentity) { op = p; p = p.Parent; }
        return p is IArgumentOperation a && a.Parameter != null && a.Parameter.RefKind is RefKind.Ref or RefKind.Out
            || p is IVariableDeclaratorOperation || p is IVariableInitializerOperation vi && vi.Parent is IVariableDeclaratorOperation vd && vd.Symbol.RefKind != RefKind.None
            || p is IReturnOperation r && IsRefReturn(r);
    }

    // ------------------------------------------------------------------------------------------------ written fields
    // Which engine fields a call of a method can write, through every engine method it calls (an override of a
    // virtual one included), and through any lambda or method group when it invokes a delegate or hands one to the
    // runtime. A range-for bound that is a field is loop-invariant when the loop body writes it nowhere this way.
    static Dictionary<IMethodSymbol, int>? methodIndex;
    static List<System.Collections.BitArray>? transWrites;
    static readonly Dictionary<IFieldSymbol, int> fieldIndex = new(SymbolEqualityComparer.Default);
    static System.Collections.BitArray? escapingWrites;

    static int FieldNo(IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (!fieldIndex.TryGetValue(f, out var k)) { k = fieldIndex.Count; fieldIndex[f] = k; }
        return k;
    }

    static IEnumerable<IOperation> BodiesOf(IMethodSymbol m)
    {
        foreach (var sr in m.OriginalDefinition.DeclaringSyntaxReferences)
        {
            var syn = sr.GetSyntax();
            if (syn is BaseMethodDeclarationSyntax bm)
            {
                if (bm.Body != null && M(bm).GetOperation(bm.Body) is IOperation b) yield return b;
                else if (bm.ExpressionBody != null && M(bm).GetOperation(bm.ExpressionBody) is IOperation e) yield return e;
                if (bm is ConstructorDeclarationSyntax cd && cd.Initializer != null && M(cd).GetOperation(cd.Initializer) is IOperation ci) yield return ci;
            }
        }
    }

    /// <summary>The fields op writes, the engine methods it calls, and whether it may run a delegate.</summary>
    static (List<int> writes, List<IMethodSymbol> calls, bool dlg) Effects(IOperation root)
    {
        var w = new List<int>(); var c = new List<IMethodSymbol>(); bool dlg = false;
        foreach (var d in root.DescendantsAndSelf())
        {
            switch (d)
            {
                case IAssignmentOperation a when StripConvS(a.Target) is IFieldReferenceOperation f: w.Add(FieldNo(f.Field)); break;
                case IIncrementOrDecrementOperation i when StripConvS(i.Target) is IFieldReferenceOperation f2: w.Add(FieldNo(f2.Field)); break;
                case IInvocationOperation inv:
                    if (inv.TargetMethod.MethodKind == MethodKind.DelegateInvoke) dlg = true;
                    else if (IsEngine(inv.TargetMethod.ContainingType)) c.Add(inv.TargetMethod.OriginalDefinition);
                    else if (inv.Arguments.Any(x => x.Value.Type?.TypeKind == TypeKind.Delegate)) dlg = true;
                    break;
                case IObjectCreationOperation oc when oc.Constructor != null:
                    if (IsEngine(oc.Constructor.ContainingType)) c.Add(oc.Constructor.OriginalDefinition);
                    else if (oc.Arguments.Any(x => x.Value.Type?.TypeKind == TypeKind.Delegate)) dlg = true;
                    break;
            }
        }
        return (w, c, dlg);
    }

    static IOperation StripConvS(IOperation op) { while (op is IConversionOperation cv && cv.Conversion.IsIdentity) op = cv.Operand; return op; }

    static void ComputeWrites()
    {
        var methods = new List<IMethodSymbol>();
        methodIndex = new(SymbolEqualityComparer.Default);
        foreach (var t in engineTypes)
            foreach (var m in t.GetMembers().OfType<IMethodSymbol>())
                if (m.DeclaringSyntaxReferences.Length > 0 && !methodIndex.ContainsKey(m.OriginalDefinition)) { methodIndex[m.OriginalDefinition] = methods.Count; methods.Add(m.OriginalDefinition); }
        var overrides = new Dictionary<IMethodSymbol, List<IMethodSymbol>>(SymbolEqualityComparer.Default);
        foreach (var m in methods)
            for (var o = m.OverriddenMethod; o != null; o = o.OverriddenMethod)
            {
                var od = o.OriginalDefinition;
                if (!overrides.TryGetValue(od, out var l)) overrides[od] = l = new List<IMethodSymbol>();
                l.Add(m);
            }
        var eff = new List<(List<int> writes, List<int> calls, bool dlg)>();
        var escW = new List<int>(); var escC = new List<int>(); bool escD = false;
        void AddCalls(List<IMethodSymbol> c, List<int> into)
        {
            foreach (var cm in c)
            {
                if (methodIndex!.TryGetValue(cm, out var k)) into.Add(k);
                if (overrides.TryGetValue(cm, out var ol)) foreach (var x in ol) if (methodIndex.TryGetValue(x, out var k2)) into.Add(k2);
            }
        }
        foreach (var m in methods)
        {
            var ws = new List<int>(); var cs = new List<int>(); bool dlg = false;
            foreach (var body in BodiesOf(m))
            {
                var (w, c, d) = Effects(body);
                ws.AddRange(w); dlg |= d;
                AddCalls(c, cs);
                foreach (var d2 in body.Descendants())
                {
                    if (d2 is IMethodReferenceOperation mr && methodIndex.TryGetValue(mr.Method.OriginalDefinition, out var k3)) escC.Add(k3);
                    if (d2 is IAnonymousFunctionOperation af)
                    {
                        var (lw, lc, ld) = Effects(af.Body);
                        escW.AddRange(lw); escD |= ld; AddCalls(lc, escC);
                    }
                }
            }
            eff.Add((ws, cs, dlg));
        }
        foreach (var t in engineTypes)
            foreach (var f in t.GetMembers().OfType<IFieldSymbol>())
                foreach (var sr in f.DeclaringSyntaxReferences)
                    if (sr.GetSyntax() is VariableDeclaratorSyntax vd && vd.Initializer != null && M(vd).GetOperation(vd.Initializer) is IOperation fo)
                        foreach (var af in fo.Descendants().OfType<IAnonymousFunctionOperation>())
                        {
                            var (lw, lc, ld) = Effects(af.Body);
                            escW.AddRange(lw); escD |= ld; AddCalls(lc, escC);
                        }
        int ESC = methods.Count;
        eff.Add((escW, escC, escD));
        int nf() => fieldIndex.Count + 1;
        var sets = new List<System.Collections.BitArray>();
        for (int i = 0; i < eff.Count; i++) { var b = new System.Collections.BitArray(nf()); foreach (var w in eff[i].writes) b[w] = true; sets.Add(b); }
        bool changed = true;
        int rounds = 0;
        while (changed && rounds++ < 500)
        {
            changed = false;
            for (int i = 0; i < eff.Count; i++)
            {
                var b = (System.Collections.BitArray)sets[i].Clone();
                foreach (var c in eff[i].calls) b.Or(sets[c]);
                if (eff[i].dlg) b.Or(sets[ESC]);
                if (!SameBits(b, sets[i])) { sets[i] = b; changed = true; }
            }
        }
        if (changed) Note("written-field analysis did not converge");
        transWrites = sets;
        escapingWrites = sets[ESC];
    }

    static bool SameBits(System.Collections.BitArray a, System.Collections.BitArray b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    /// <summary>Whether running op (a loop body) can write field f.</summary>
    static bool MayWrite(IOperation op, IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (fieldAddr.Contains(f)) return true;
        if (methodIndex == null) ComputeWrites();
        if (!fieldIndex.TryGetValue(f, out var fk)) return false;        // never written anywhere
        var (w, c, d) = Effects(op);
        if (w.Contains(fk)) return true;
        if (d && fk < escapingWrites!.Length && escapingWrites[fk]) return true;
        foreach (var cm in c)
        {
            if (!methodIndex!.TryGetValue(cm, out var k)) return true;
            if (fk < transWrites![k].Length && transWrites[k][fk]) return true;
            foreach (var t in engineTypes)
                foreach (var m in t.GetMembers(cm.Name).OfType<IMethodSymbol>())
                    if (IsOverrideOf(m, cm) && methodIndex.TryGetValue(m.OriginalDefinition, out var k2) && fk < transWrites[k2].Length && transWrites[k2][fk]) return true;
        }
        return false;
    }

    /// <summary>A declaration inside the body of a loop (not in a for statement's own initializer).</summary>
    static bool InLoopBody(SyntaxNode n)
    {
        for (var p = n.Parent; p != null; p = p.Parent)
        {
            if (p is MemberDeclarationSyntax || p is LambdaExpressionSyntax || p is AnonymousMethodExpressionSyntax || p is LocalFunctionStatementSyntax) return false;
            if (p is ForStatementSyntax fs && n.Ancestors().Contains(fs.Statement)) return true;
            if (p is WhileStatementSyntax ws && n.Ancestors().Contains(ws.Statement)) return true;
            if (p is DoStatementSyntax ds && n.Ancestors().Contains(ds.Statement)) return true;
            if (p is ForEachStatementSyntax fe && n.Ancestors().Contains(fe.Statement)) return true;
        }
        return false;
    }

    static bool IsRefSym(ISymbol s) => s is ILocalSymbol l && l.RefKind != RefKind.None || s is IParameterSymbol p && p.RefKind != RefKind.None;

    static bool IsInside(ISymbol? s, ISymbol lambda)
    {
        for (var x = s; x != null; x = x.ContainingSymbol) if (SymbolEqualityComparer.Default.Equals(x, lambda)) return true;
        return false;
    }

    static bool IsRefReturn(IReturnOperation r)
    {
        for (var p = r.Parent; p != null; p = p.Parent)
        {
            if (p is IAnonymousFunctionOperation af) return af.Symbol.RefKind != RefKind.None;
            if (p is IMethodBodyOperation || p is IBlockOperation && p.Parent == null) break;
        }
        var sm = r.SemanticModel;
        var md = r.Syntax.Ancestors().OfType<MethodDeclarationSyntax>().FirstOrDefault();
        return md != null && sm != null && sm.GetDeclaredSymbol(md) is IMethodSymbol ms && ms.RefKind != RefKind.None;
    }

    static void Mark(IOperation op, HashSet<ISymbol> set)
    {
        while (op is IConversionOperation cv && cv.Conversion.IsIdentity) op = cv.Operand;
        if (op is ILocalReferenceOperation l) set.Add(l.Local);
        else if (op is IParameterReferenceOperation p) set.Add(p.Parameter);
    }

    // ------------------------------------------------------------------------------------------------ types
    static readonly HashSet<string> Specializable = new() { "Vec", "Ptr", "Iter", "RevIter", "CSpan", "Opt", "Atomic", "RefAt", "RefGet" };

    /// <summary>The one-letter code of a primitive type (D, F, I, L, B, Z, S, C), or null (the Java runtime's codes).</summary>
    static string? PrimCode(ITypeSymbol t)
    {
        if (t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol en) return PrimCode(en.EnumUnderlyingType!);
        return t.SpecialType switch
        {
            SpecialType.System_Double => "D", SpecialType.System_Single => "F",
            SpecialType.System_Int32 or SpecialType.System_UInt32 => "I",
            SpecialType.System_Int64 or SpecialType.System_UInt64 => "L",
            SpecialType.System_Byte or SpecialType.System_SByte => "B",
            SpecialType.System_Boolean => "Z",
            SpecialType.System_Int16 => "S",
            SpecialType.System_UInt16 or SpecialType.System_Char => "C",
            _ => null
        };
    }

    /// <summary>A runtime type's name: the C# name (nested names joined by _), with the primitive code of its type
    /// argument for the specialised containers (Vec&lt;double&gt; is VecD), as the Java and Python runtimes name them.</summary>
    static string RuntimeTypeName(INamedTypeSymbol n)
    {
        var parts = new List<string>();
        for (var c = n; c != null; c = c.ContainingType) parts.Insert(0, StripArity(c.Name));
        var s = string.Join("_", parts);
        if (n.TypeArguments.Length == 1 && Specializable.Contains(StripArity(n.Name)) && PrimCode(n.TypeArguments[0]) is string code) s += code;
        return s;
    }

    static bool SpecializedClass(INamedTypeSymbol t) => t.IsGenericType && t.TypeArguments.Length == 1 && Specializable.Contains(StripArity(t.Name)) && PrimCode(t.TypeArguments[0]) != null;

    static bool IsStructType(ITypeSymbol t) => t.TypeKind == TypeKind.Struct && t.SpecialType == SpecialType.None && !(t is INamedTypeSymbol n && n.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T);

    static bool IsIntegral(ITypeSymbol? t) => t != null && (t.SpecialType is SpecialType.System_Int32 or SpecialType.System_Int64 or SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_SByte or SpecialType.System_Byte or SpecialType.System_Char
        || t.TypeKind == TypeKind.Enum);
    static bool IsUnsigned(ITypeSymbol? t) => t != null && (t.SpecialType is SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Byte or SpecialType.System_UInt16 or SpecialType.System_Char
        || t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol e && IsUnsigned(e.EnumUnderlyingType));
    static bool IsDouble(ITypeSymbol? t) => t != null && t.SpecialType == SpecialType.System_Double;
    static bool IsSingle(ITypeSymbol? t) => t != null && t.SpecialType == SpecialType.System_Single;
    static bool IsFloat(ITypeSymbol? t) => IsDouble(t) || IsSingle(t);
    static bool IsNumeric(ITypeSymbol? t) => IsFloat(t) || IsIntegral(t);
    static ITypeSymbol Under(ITypeSymbol t) => t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol e ? e.EnumUnderlyingType! : t;

    static int Width(ITypeSymbol? t)
    {
        if (t == null) return 0;
        t = Under(t);
        return t.SpecialType switch
        {
            SpecialType.System_Byte or SpecialType.System_SByte => 8, SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_Char => 16,
            SpecialType.System_Int32 or SpecialType.System_UInt32 => 32, SpecialType.System_Int64 or SpecialType.System_UInt64 => 64, _ => 0
        };
    }

    /// <summary>The Ruby expression that reduces x (any Ruby Integer) to the value range of integer type t: C#'s
    /// unchecked wrap-around. x must be a parenthesised or atomic expression. (Ruby, like Python, binds + more
    /// tightly than &amp;.)</summary>
    static string WrapInt(string x, ITypeSymbol t)
    {
        int w = Width(t);
        bool u = IsUnsigned(t);
        if (w == 0) return x;
        var mask = w == 64 ? "0xFFFFFFFFFFFFFFFF" : w == 32 ? "0xFFFFFFFF" : w == 16 ? "0xFFFF" : "0xFF";
        if (u) return "(" + x + " & " + mask + ")";
        var half = w == 64 ? "0x8000000000000000" : w == 32 ? "0x80000000" : w == 16 ? "0x8000" : "0x80";
        return "((" + x + " + " + half + " & " + mask + ") - " + half + ")";
    }

    static string MaskOf(ITypeSymbol t)
    {
        int w = Width(t);
        return w == 64 ? "0xFFFFFFFFFFFFFFFF" : w == 32 ? "0xFFFFFFFF" : w == 16 ? "0xFFFF" : "0xFF";
    }

    /// <summary>The value a field, array element or local of type t starts with (C#'s default).</summary>
    static string DefaultOf(ITypeSymbol t)
    {
        if (t.SpecialType == SpecialType.System_Boolean) return "false";
        if (IsFloat(t)) return "0.0";
        if (IsIntegral(t)) return "0";
        if (IsStructType(t) && t is INamedTypeSymbol n)
        {
            if (IsRuntime(n)) return Use(RuntimeTypeName(n) + "_ZERO", "default(" + n.OriginalDefinition.ToDisplayString() + ")" + (SpecializedClass(n) ? " (" + n.TypeArguments[0].ToDisplayString() + ")" : ""));
            if (IsSystem(n) && n.Name == "ValueTuple") return "nil";
            return Todo("engine struct " + n.Name);
        }
        return "nil";
    }

    // makers that are not one of the runtime's MK_* constants: one top-level constant each, by text
    static readonly SortedDictionary<string, string> makerConsts = new(StringComparer.Ordinal);

    static string MakerConst(string body)
    {
        foreach (var kv in makerConsts) if (kv.Value == body) return kv.Key;
        var n = "K_MK" + makerConsts.Count;
        makerConsts[n] = body;
        return n;
    }

    /// <summary>An element maker: an object whose call() makes a default T, as C#'s Elem&lt;T&gt;.Make does
    /// (default(T) for a value type, the parameterless constructor of a class that has one, else null). The
    /// runtime's makers MK_* return immutable values; the others are lambdas held in top-level constants.</summary>
    static string Maker(ITypeSymbol t)
    {
        if (t.SpecialType == SpecialType.System_Boolean) return Use("MK_Z", "maker: false");
        if (IsFloat(t)) return Use("MK_D", "maker: 0.0");
        if (IsIntegral(t)) return Use("MK_I", "maker: 0");
        if (IsStructType(t) && t is INamedTypeSymbol sn && IsRuntime(sn)) return Use("MK_" + RuntimeTypeName(sn), "maker: default(" + sn.OriginalDefinition.ToDisplayString() + ")");
        if (t is INamedTypeSymbol n && IsEngine(n) && n.TypeKind == TypeKind.Class && !n.IsAbstract && !n.IsStatic)
        {
            var c = n.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length == 0 && k.DeclaredAccessibility == Accessibility.Public);
            if (c == null) return Use("MK_N", "maker: null");
            return MakerConst("-> { " + CtorCall(c, "") + " }");
        }
        if (t is INamedTypeSymbol r && IsRuntime(r) && r.TypeKind == TypeKind.Class && !r.IsAbstract)
        {
            var ctor = r.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length == 0 && k.DeclaredAccessibility == Accessibility.Public)
                ?? r.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length > 0 && k.Parameters.All(p => p.IsOptional) && k.DeclaredAccessibility == Accessibility.Public);
            if (ctor == null) return Use("MK_N", "maker: null");
            var nm = StripArity(r.Name);
            var fname = RuntimeCtorName(ctor, r);
            var extra = new List<string>();
            if (!SpecializedClass(r) && r.IsGenericType)
            {
                // the map constructors' leading optional parameters (hash, equality, ordering) are null
                if (ctor.Parameters.Length > 0)
                    foreach (var p in ctor.Parameters)
                        extra.Add(p.Type is INamedTypeSymbol ft && IsSystem(ft) && ft.Name == "Func" && ft.TypeArguments.Length == 1 ? Maker(((INamedTypeSymbol)p.Type).TypeArguments[0]) : "nil");
                else if (makerSlots.TryGetValue(nm, out var slots)) foreach (var k in slots) extra.Add(Maker(r.TypeArguments[k]));
                else if (nm is "Pair" or "Tup") foreach (var ta in r.TypeArguments) extra.Add(Maker(ta));
            }
            Use(fname, "new " + ctor.OriginalDefinition.ToDisplayString() + (SpecializedClass(r) ? " (" + r.TypeArguments[0].ToDisplayString() + ")" : "") + (extra.Count > 0 ? " + makers" : ""));
            return MakerConst("-> { " + fname + "(" + string.Join(", ", extra) + ") }");
        }
        return Use("MK_N", "maker: null");
    }

    static readonly Dictionary<string, int[]> makerSlots = new() { ["Vec"] = new[] { 0 }, ["Map"] = new[] { 1 }, ["UMap"] = new[] { 1 }, ["UMapC"] = new[] { 1 } };

    /// <summary>A runtime constructor's name: New and the class's name, with Go's suffix of the generic
    /// definition's parameter types when the class has several constructors (none for the parameterless one).</summary>
    static string RuntimeCtorName(IMethodSymbol c, INamedTypeSymbol t)
    {
        var ctors = t.OriginalDefinition.InstanceConstructors.Where(k => k.DeclaredAccessibility != Accessibility.Private).ToList();
        var sfx = ctors.Count > 1 && c.Parameters.Length > 0 ? "_" + string.Join("_", c.OriginalDefinition.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : ""))) : "";
        return "New" + RuntimeTypeName(t) + sfx;
    }

    // ------------------------------------------------------------------------------------------------ engine constructors
    // An engine object is made in two steps: Klass.new allocates it (initialize sets every field of its hierarchy to
    // its C# default: what the protected Raw constructor does), and a constructor with a body is a method
    // ctor_<Type><sfx> run on it by the top-level factory <Type>__new<sfx>. The methods are named by their class, so
    // a constructor chained to a base class's is an ordinary call of the inherited method.

    static bool IsRawCtor(IMethodSymbol c) => c.Parameters.Length == 1 && c.Parameters[0].Type.Name == "Raw" && IsRuntime(c.Parameters[0].Type);

    static readonly Dictionary<IMethodSymbol, bool> trivialCtor = new(SymbolEqualityComparer.Default);

    /// <summary>A constructor that does nothing beyond the allocation: an empty body chained to the Raw constructor
    /// or to another trivial one (or an implicit parameterless one of a class with no instance field initializers).</summary>
    static bool IsTrivialCtor(IMethodSymbol c)
    {
        c = c.OriginalDefinition;
        if (trivialCtor.TryGetValue(c, out var v)) return v;
        trivialCtor[c] = false;
        bool r;
        var decl = c.DeclaringSyntaxReferences.Select(x => x.GetSyntax()).OfType<ConstructorDeclarationSyntax>().FirstOrDefault();
        if (decl == null)
        {
            var b = c.ContainingType.BaseType;
            r = b == null || !IsEngine(b) || b.InstanceConstructors.Where(k => k.Parameters.Length == 0).All(IsTrivialCtor);
            if (HasInstanceFieldInits(c.ContainingType)) r = false;
        }
        else
        {
            bool emptyBody = decl.Body == null ? decl.ExpressionBody == null : decl.Body.Statements.Count == 0;
            r = emptyBody && !HasInstanceFieldInits(c.ContainingType);
            if (r && decl.Initializer != null)
            {
                var init = M(decl).GetOperation(decl.Initializer);
                var inv = init is IExpressionStatementOperation es ? es.Operation : init;
                if (inv is IInvocationOperation ci)
                {
                    var target = ci.TargetMethod;
                    if (IsEngine(target.ContainingType)) r = IsTrivialCtor(target);
                    else r = IsRawCtor(target) || target.Parameters.Length == 0;
                }
                else r = false;
            }
            else if (r && c.ContainingType.BaseType is INamedTypeSymbol bt && IsEngine(bt))
                r = bt.InstanceConstructors.Where(k => k.Parameters.Length == 0).All(IsTrivialCtor);
        }
        trivialCtor[c] = r;
        return r;
    }

    static bool HasInstanceFieldInits(INamedTypeSymbol t) =>
        t.GetMembers().OfType<IFieldSymbol>().Any(f => !f.IsStatic && !f.IsConst && f.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<VariableDeclaratorSyntax>().Any(v => v.Initializer != null));

    static string CtorSuffix(IMethodSymbol c)
    {
        if (c.Parameters.Length == 0) return "";
        return "_" + string.Join("_", c.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : "")));
    }

    /// <summary>The method that runs engine constructor c on an allocated object.</summary>
    static string CtorMethod(IMethodSymbol c)
    {
        var n = "ctor_" + TypeIdent(c.ContainingType) + CtorSuffix(c);
        engineMembers.Add(n);
        return n;
    }

    /// <summary>C#'s new T(args) for engine constructor c, with the argument text.</summary>
    static string CtorCall(IMethodSymbol c, string args)
    {
        var t = c.ContainingType;
        if (IsTrivialCtor(c)) return ClassConst(t) + ".new";
        return TypeIdent(t) + "__new" + CtorSuffix(c) + "(" + args + ")";
    }

    // ------------------------------------------------------------------------------------------------ the file
    static readonly StringBuilder classText = new();
    static readonly StringBuilder funcText = new();
    static readonly List<(INamedTypeSymbol owner, string text, int order)> staticInits = new();
    static readonly List<string> staticDefaults = new();
    static readonly SortedDictionary<string, string> moduleConsts = new(StringComparer.Ordinal);
    static readonly SortedDictionary<string, string> helperClasses = new(StringComparer.Ordinal);
    static readonly SortedDictionary<string, string> unboundMethods = new(StringComparer.Ordinal);

    static string Module(List<SyntaxTree> gen)
    {
        var classes = engineTypes.Where(IsClassEmitted).ToList();
        var order = new List<INamedTypeSymbol>();
        var done = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        void Visit(INamedTypeSymbol c)
        {
            if (done.Contains(c)) return;
            done.Add(c);
            if (c.BaseType is INamedTypeSymbol b && IsEngine(b) && IsClassEmitted(b.OriginalDefinition)) Visit(b.OriginalDefinition);
            order.Add(c);
        }
        foreach (var c in classes) Visit(c);
        foreach (var s in order)
        {
            try { ClassDecl(s); }
            catch (Todo e) { classText.Append("# TODO class ").Append(ClassConst(s)).Append(": ").Append(e.Message).Append('\n'); }
        }
        foreach (var s in engineTypes.Where(t => t.TypeKind == TypeKind.Class && t.IsStatic))
        {
            try { StaticMembers(s); }
            catch (Todo e) { funcText.Append("# TODO static class ").Append(TypeIdent(s)).Append(": ").Append(e.Message).Append('\n'); }
        }
        foreach (var s in engineTypes.Where(t => t.TypeKind != TypeKind.Class && t.TypeKind != TypeKind.Enum && t.TypeKind != TypeKind.Delegate))
            Note("type kind " + s.TypeKind + " " + s.Name);

        var sb = new StringBuilder();
        sb.Append("# encoding: binary\n# frozen_string_literal: true\n");
        sb.Append("# Code generated by tools/cs2x/Cs2Rb.cs from cs/gen and cs/runtime/Hand_*.cs. DO NOT EDIT.\n");
        sb.Append("# The OpenSWMM 6 engine (C++, Caleb Buahin and the OpenSWMM contributors; Apache-2.0, HydroCouple Developers)\n");
        sb.Append("# translated mechanically C++ -> C# -> Ruby. It runs on the runtime in ruby/cpp (module Cpp, included into Object\n");
        sb.Append("# by ruby/runswmm6.rb before this file is loaded). Written by Claude (Anthropic) for Robert Dickinson; see AI-USE.md.\n\n");
        sb.Append("K_INF = Float::INFINITY\n");
        foreach (var kv in moduleConsts) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append('\n');
        sb.Append("\n# ---------------------------------------------------------------- classes\n\n");
        sb.Append(classText);
        sb.Append("\n# ---------------------------------------------------------------- functions\n\n");
        sb.Append(funcText);
        sb.Append("\n# ---------------------------------------------------------------- references to fields\n\n");
        foreach (var kv in helperClasses) sb.Append(kv.Value).Append('\n');
        sb.Append("\n# ---------------------------------------------------------------- base-class methods called directly\n\n");
        foreach (var kv in unboundMethods) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append('\n');
        sb.Append("\n# ---------------------------------------------------------------- element makers\n\n");
        foreach (var kv in makerConsts) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append('\n');
        sb.Append("\n# ---------------------------------------------------------------- static fields\n\n");
        foreach (var d in staticDefaults) sb.Append(d).Append('\n');
        sb.Append("\n\n# ---------------------------------------------------------------- static initialisation\n\n");
        foreach (var (owner, text, _) in OrderStaticInits()) sb.Append(text).Append('\n');
        return sb.ToString();
    }

    static void ClassDecl(INamedTypeSymbol s)
    {
        var nm = ClassConst(s);
        string? sup = null;
        string? runtimeBase = null;
        var b = s.BaseType;
        if (b != null && b.SpecialType != SpecialType.System_Object)
        {
            if (IsEngine(b)) sup = ClassConst(b);
            else if (IsRuntime(b)) { runtimeBase = UseC(RuntimeTypeName(b), "type " + b.OriginalDefinition.ToDisplayString() + " (an engine base class)"); sup = runtimeBase; }
            else if (IsSystem(b) && b.Name == "Exception") { runtimeBase = UseC("CppException", "type Cpp.CppException"); sup = runtimeBase; }
            else Note("base type " + b.ToDisplayString());
        }
        var mods = new List<string>();
        foreach (var i in s.Interfaces)
        {
            if (b != null && b.AllInterfaces.Contains(i)) continue;
            if (IsRuntime(i)) mods.Add(UseC(StripArity(i.Name), "interface " + i.OriginalDefinition.ToDisplayString() + " (a module)"));
            else if (IsSystem(i) && i.Name == "IDisposable") mods.Add(UseC("IDisposable", "interface System.IDisposable (a module)"));
            else if (IsSystem(i)) { }
            else Note("interface " + i.ToDisplayString());
        }
        var sb = classText;
        sb.Append("class ").Append(nm);
        if (sup != null) sb.Append(" < ").Append(sup);
        sb.Append('\n');
        foreach (var mo in mods.Distinct()) sb.Append("  include ").Append(mo).Append('\n');
        var own = s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared && !f.IsStatic && !f.IsConst).ToList();
        if (own.Count > 0) sb.Append("  attr_accessor ").Append(string.Join(", ", own.Select(f => ":" + FieldIdent(f)))).Append('\n');
        // allocation: every field of the hierarchy to its default
        var all = new List<IFieldSymbol>();
        for (var c = s; c != null && IsEngine(c); c = c.BaseType) all.InsertRange(0, c.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared && !f.IsStatic && !f.IsConst));
        if (own.Count > 0 || runtimeBase != null)
        {
            sb.Append("\n  def initialize\n");
            if (runtimeBase != null) sb.Append("    super()\n");
            foreach (var f in all) sb.Append("    @").Append(FieldIdent(f)).Append(" = ").Append(DefaultOf(f.Type)).Append('\n');
            sb.Append("  end\n");
        }
        foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared && (f.IsStatic || f.IsConst)))
        {
            try { StaticField(f); }
            catch (Todo e) { staticDefaults.Add("# TODO field " + f.Name + ": " + e.Message); }
        }
        var decls = s.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<ClassDeclarationSyntax>().ToList();
        foreach (var cd in decls)
            foreach (var m in cd.Members)
            {
                try
                {
                    switch (m)
                    {
                        case MethodDeclarationSyntax md: MethodDecl(md, s); break;
                        case ConstructorDeclarationSyntax ctor: CtorDecl(ctor, s); break;
                        case FieldDeclarationSyntax: break;
                        case BaseTypeDeclarationSyntax: break;      // nested: a class of its own
                        case DelegateDeclarationSyntax: break;
                        default: sb.Append("  # TODO member ").Append(m.Kind()).Append('\n'); Note("member " + m.Kind()); break;
                    }
                }
                catch (Todo e) { sb.Append("  # TODO ").Append(e.Message).Append('\n'); }
                catch (Exception e) when (e is not global::Todo) { sb.Append("  # TODO translator error: ").Append(e.GetType().Name).Append(' ').Append(e.Message.Replace("\n", " ")).Append('\n'); Note("translator error " + e.GetType().Name + ": " + e.Message.Split('\n')[0]); }
            }
        if (!decls.SelectMany(d => d.Members).OfType<ConstructorDeclarationSyntax>().Any(c => !c.Modifiers.Any(SyntaxKind.StaticKeyword)))
            foreach (var c in s.InstanceConstructors.Where(c => c.IsImplicitlyDeclared && !IsTrivialCtor(c)))
                Note("implicit constructor with work " + s.Name);
        sb.Append("end\n\n");
    }

    static void StaticMembers(INamedTypeSymbol s)
    {
        foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared))
        {
            try { StaticField(f); }
            catch (Todo e) { staticDefaults.Add("# TODO field " + f.Name + ": " + e.Message); }
        }
        var decls = s.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<ClassDeclarationSyntax>().ToList();
        foreach (var cd in decls)
            foreach (var m in cd.Members)
            {
                try
                {
                    switch (m)
                    {
                        case MethodDeclarationSyntax md: MethodDecl(md, s); break;
                        case ConstructorDeclarationSyntax ctor: CtorDecl(ctor, s); break;
                        case FieldDeclarationSyntax: break;
                        case BaseTypeDeclarationSyntax: break;
                        case DelegateDeclarationSyntax: break;
                        default: funcText.Append("# TODO member ").Append(m.Kind()).Append('\n'); Note("member " + m.Kind()); break;
                    }
                }
                catch (Todo e) { funcText.Append("# TODO ").Append(e.Message).Append('\n'); }
                catch (Exception e) when (e is not global::Todo) { funcText.Append("# TODO translator error: ").Append(e.GetType().Name).Append(' ').Append(e.Message.Replace("\n", " ")).Append('\n'); Note("translator error " + e.GetType().Name + ": " + e.Message.Split('\n')[0]); }
            }
    }

    static int staticOrder;

    static void StaticField(IFieldSymbol f)
    {
        var name = StaticFieldName(f);
        if (f.IsConst)
        {
            staticDefaults.Add(name + " = " + RbFn.Const(f.ConstantValue, f.Type));
            return;
        }
        staticDefaults.Add(name + " = " + DefaultOf(f.Type));
        var syn = f.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<VariableDeclaratorSyntax>().FirstOrDefault();
        if (syn?.Initializer == null) return;
        var op = M(syn).GetOperation(syn.Initializer) is IFieldInitializerOperation fi ? fi.Value : M(syn).GetOperation(syn.Initializer.Value);
        if (op == null) { Todo("field initializer"); return; }
        var fn = new RbFn(null, f.ContainingType, 1);
        var lines = new List<string>();
        try
        {
            var val = fn.ValueOf(op, f.Type);
            if (fn.Pre.Count == 0 && RbFn.IsLiteral(val))
            {
                staticDefaults[^1] = name + " = " + RbFn.StripPub(val);
                return;
            }
            fn.FlushTo(lines, 1);
            lines.Add("  " + name + " = " + RbFn.StripPub(val));
        }
        catch (Todo e) { lines.Add("  raise " + RbFn.TodoExc(e.Message)); }
        var fname = "_si_" + name.Substring(1);
        var text = "def " + fname + "\n" + fn.FuncPrologue(1) + string.Concat(lines.Select(l => l + "\n")) + "end\n" + fname + "()\n";
        staticInits.Add((f.ContainingType, text, staticOrder++));
        fn.CollectDeps(op, f.ContainingType);
        initDeps[(f.ContainingType, staticOrder - 1)] = fn.Deps;
    }

    static readonly Dictionary<(INamedTypeSymbol, int), HashSet<INamedTypeSymbol>> initDeps = new();

    /// <summary>The static initialisers in an order where a class's are run before those of a class that reads its
    /// static fields (directly or through the functions it calls), the declaration order otherwise; C# runs a class's
    /// initialisers, in textual order, when the class is first used.</summary>
    static List<(INamedTypeSymbol owner, string text, int order)> OrderStaticInits()
    {
        var byClass = staticInits.GroupBy(x => x.owner, SymbolEqualityComparer.Default).Select(g => (owner: (INamedTypeSymbol)g.Key!, items: g.OrderBy(x => x.order).ToList())).ToList();
        var first = byClass.ToDictionary(x => x.owner, x => x.items[0].order, SymbolEqualityComparer.Default);
        var deps = new Dictionary<INamedTypeSymbol, HashSet<INamedTypeSymbol>>(SymbolEqualityComparer.Default);
        foreach (var (owner, items) in byClass)
        {
            var d = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
            foreach (var it in items)
                if (initDeps.TryGetValue((owner, it.order), out var ds)) foreach (var x in ds) if (!SymbolEqualityComparer.Default.Equals(x, owner) && first.ContainsKey(x)) d.Add(x);
            deps[owner] = d;
        }
        var outv = new List<(INamedTypeSymbol, string, int)>();
        var state = new Dictionary<INamedTypeSymbol, int>(SymbolEqualityComparer.Default);
        void Visit(INamedTypeSymbol c)
        {
            if (state.TryGetValue(c, out var st)) { if (st == 1) Note("static initialisation cycle (declaration order kept) " + c.Name); return; }
            state[c] = 1;
            foreach (var d in deps[c].OrderBy(x => first[x])) Visit(d);
            state[c] = 2;
            outv.AddRange(byClass.First(x => SymbolEqualityComparer.Default.Equals(x.owner, c)).items);
        }
        foreach (var (owner, _) in byClass.OrderBy(x => x.items[0].order)) Visit(owner);
        return outv;
    }

    static void MethodDecl(MethodDeclarationSyntax md, INamedTypeSymbol s)
    {
        var m = (IMethodSymbol)M(md).GetDeclaredSymbol(md)!;
        var inClass = !m.IsStatic && IsClassEmitted(s);
        int ind = inClass ? 1 : 0;
        var fn = new RbFn(m, s, ind + 1);
        var ps = new List<string>();
        foreach (var p in m.Parameters) ps.Add(fn.DeclareParam(p));
        var name = m.IsStatic ? StaticFuncName(m) : MethodIdent(m);
        var head = new string(' ', 2 * ind) + "def " + name + (ps.Count > 0 ? "(" + string.Join(", ", ps) + ")" : "") + "\n";
        string body;
        if (m.IsAbstract) body = new string(' ', 2 * (ind + 1)) + "raise " + RbFn.TodoExc("abstract method " + m.Name) + "\n";
        else
        {
            IOperation? op = md.Body != null ? M(md).GetOperation(md.Body) : md.ExpressionBody != null ? M(md).GetOperation(md.ExpressionBody) : null;
            try { body = op == null ? "" : fn.Body(op, m); }
            catch (Todo e) { body = new string(' ', 2 * (ind + 1)) + "raise " + RbFn.TodoExc(e.Message) + "\n"; }
            body = fn.FuncPrologue(ind + 1) + body;
        }
        var text = head + body + new string(' ', 2 * ind) + "end\n";
        if (inClass) classText.Append('\n').Append(text);
        else funcText.Append(text).Append('\n');
    }

    static void CtorDecl(ConstructorDeclarationSyntax cd, INamedTypeSymbol s)
    {
        var c = (IMethodSymbol)M(cd).GetDeclaredSymbol(cd)!;
        if (c.IsStatic)
        {
            var fn0 = new RbFn(c, s, 1);
            var body0 = cd.Body != null ? fn0.Body(M(cd).GetOperation(cd.Body)!, c) : "";
            var nm0 = "_si_" + TypeIdent(s) + "__cctor";
            var text0 = "def " + nm0 + "\n" + fn0.FuncPrologue(1) + body0 + "end\n" + nm0 + "()\n";
            staticInits.Add((s, text0, staticOrder++));
            fn0.CollectDeps(M(cd).GetOperation(cd.Body!)!, s);
            initDeps[(s, staticOrder - 1)] = fn0.Deps;
            return;
        }
        if (IsTrivialCtor(c)) return;
        if (IsRawCtor(c))
        {
            Note("raw constructor with a body " + s.Name);
            return;
        }
        // ctor_<Type><sfx>(params): the base or this constructor it chains to, then its body
        var fn = new RbFn(c, s, 2);
        var ps = new List<string>();
        foreach (var p in c.Parameters) ps.Add(fn.DeclareParam(p));
        var lines = new List<string>();
        if (cd.Initializer != null && M(cd).GetOperation(cd.Initializer) is IOperation init)
        {
            var inv = init is IExpressionStatementOperation es ? es.Operation : init;
            if (inv is IInvocationOperation ci)
            {
                var target = ci.TargetMethod;
                if (IsEngine(target.ContainingType))
                {
                    if (!IsTrivialCtor(target))
                    {
                        var args = fn.ArgList(target, ci.Arguments);
                        fn.FlushTo(lines, 2);
                        lines.Add("    " + CtorMethod(target) + "(" + args + ")");
                    }
                }
                else if (IsRuntime(target.ContainingType) && !IsRawCtor(target) && target.Parameters.Length > 0)
                {
                    var args = fn.ArgList(target, ci.Arguments);
                    fn.FlushTo(lines, 2);
                    var rb = RuntimeTypeName(target.ContainingType);
                    var mn = "_ctor" + CtorSuffix(target);
                    lines.Add("    " + mn + "(" + args + ")");
                    UseM(mn, "constructor " + target.ToDisplayString() + " run on an allocated object of an engine class derived from " + rb);
                }
            }
            else Todo("constructor initializer " + inv.Kind);
        }
        var body = cd.Body != null ? fn.Body(M(cd).GetOperation(cd.Body)!, c) : "";
        var cm = CtorMethod(c);
        classText.Append("\n  def ").Append(cm).Append(ps.Count > 0 ? "(" + string.Join(", ", ps) + ")" : "").Append('\n').Append(fn.FuncPrologue(2));
        foreach (var l in lines) classText.Append(l).Append('\n');
        classText.Append(body);
        classText.Append("  end\n");
        if (HasInstanceFieldInits(s)) Note("instance field initializer (not translated) in " + s.Name);
        // the factory; a constructor that only runs one method of the object calls it directly
        var tn = TypeIdent(s);
        var fps = string.Join(", ", c.Parameters.Select((p, i) => "a" + i));
        var bl = body.Split('\n').Where(x => x.Trim().Length > 0).ToList();
        var call = "o." + cm + "(" + fps + ")";
        if (lines.Count == 0 && fps.Length == 0 && bl.Count == 1 && System.Text.RegularExpressions.Regex.IsMatch(bl[0], @"^ {4}self\.[A-Za-z_][A-Za-z_0-9]*\(\)$"))
            call = "o." + bl[0].Trim().Substring(5);
        var fname = tn + "__new" + CtorSuffix(c);
        engineFunctions.Add(fname);
        funcText.Append("def ").Append(fname).Append(fps.Length > 0 ? "(" + fps + ")" : "").Append("\n  o = ").Append(ClassConst(s)).Append(".new\n  ").Append(call)
            .Append("\n  o\nend\n\n");
    }
}
