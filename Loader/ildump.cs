using System;
using System.Collections.Generic;
using System.Reflection;
using System.Reflection.Emit;
using System.Text;

internal static class Dump
{
    private static Dictionary<int, OpCode> _ops = new Dictionary<int, OpCode>();

    private static void Init()
    {
        FieldInfo[] fields = typeof(OpCodes).GetFields(BindingFlags.Public | BindingFlags.Static);
        foreach (FieldInfo f in fields)
        {
            OpCode op = (OpCode)f.GetValue(null);
            _ops[(ushort)op.Value] = op;
        }
    }

    private static string Resolve(Module mod, OpCode op, byte[] il, ref int pos, int baseOffset, int[] targetOffsets)
    {
        OperandType ot = op.OperandType;
        switch (ot)
        {
            case OperandType.InlineNone:
                return "";
            case OperandType.ShortInlineBrTarget:
            {
                sbyte d = (sbyte)il[pos]; pos += 1;
                return "IL_" + (pos + d).ToString("X4");
            }
            case OperandType.InlineBrTarget:
            {
                int d = BitConverter.ToInt32(il, pos); pos += 4;
                return "IL_" + (pos + d).ToString("X4");
            }
            case OperandType.ShortInlineI:
            {
                sbyte v = (sbyte)il[pos]; pos += 1;
                return v.ToString();
            }
            case OperandType.InlineI:
            {
                int v = BitConverter.ToInt32(il, pos); pos += 4;
                return v.ToString();
            }
            case OperandType.InlineI8:
            {
                long v = BitConverter.ToInt64(il, pos); pos += 8;
                return v.ToString();
            }
            case OperandType.ShortInlineR:
            {
                float v = BitConverter.ToSingle(il, pos); pos += 4;
                return v.ToString();
            }
            case OperandType.InlineR:
            {
                double v = BitConverter.ToDouble(il, pos); pos += 8;
                return v.ToString();
            }
            case OperandType.ShortInlineVar:
            {
                byte v = il[pos]; pos += 1;
                return v.ToString();
            }
            case OperandType.InlineVar:
            {
                ushort v = BitConverter.ToUInt16(il, pos); pos += 2;
                return v.ToString();
            }
            case OperandType.InlineString:
            {
                int tok = BitConverter.ToInt32(il, pos); pos += 4;
                try { return "\"" + mod.ResolveString(tok).Replace("\r", "\\r").Replace("\n", "\\n") + "\""; }
                catch { return "str(0x" + tok.ToString("X8") + ")"; }
            }
            case OperandType.InlineField:
            case OperandType.InlineMethod:
            case OperandType.InlineType:
            case OperandType.InlineTok:
            {
                int tok = BitConverter.ToInt32(il, pos); pos += 4;
                try
                {
                    MemberInfo mi = mod.ResolveMember(tok);
                    return mi.DeclaringType == null ? mi.Name : mi.DeclaringType.Name + "::" + mi.Name;
                }
                catch { return "tok(0x" + tok.ToString("X8") + ")"; }
            }
            case OperandType.InlineSwitch:
            {
                int n = BitConverter.ToInt32(il, pos); pos += 4;
                StringBuilder sb = new StringBuilder();
                int basePos = pos + 4 * n;
                for (int i = 0; i < n; i++)
                {
                    int d = BitConverter.ToInt32(il, pos); pos += 4;
                    if (i > 0) sb.Append(", ");
                    sb.Append("IL_").Append((basePos + d).ToString("X4"));
                }
                return sb.ToString();
            }
            case OperandType.InlineSig:
            {
                int tok = BitConverter.ToInt32(il, pos); pos += 4;
                return "sig(0x" + tok.ToString("X8") + ")";
            }
            default:
                return "?";
        }
    }

    public static void DumpMethod(MethodBase m)
    {
        Console.WriteLine("=== " + m.DeclaringType.FullName + "::" + m.Name);
        MethodBody body;
        try { body = m.GetMethodBody(); } catch { Console.WriteLine("  <no body>"); return; }
        if (body == null) { Console.WriteLine("  <no body>"); return; }
        byte[] il = body.GetILAsByteArray();
        Module mod = m.Module;
        int pos = 0;
        while (pos < il.Length)
        {
            int start = pos;
            int code = il[pos++];
            if (code == 0xFE)
            {
                code = 0xFE00 | il[pos++];
            }
            OpCode op;
            if (!_ops.TryGetValue(code, out op))
            {
                Console.WriteLine("  IL_" + start.ToString("X4") + ": <unknown 0x" + code.ToString("X") + ">");
                break;
            }
            string operand = Resolve(mod, op, il, ref pos, start, null);
            Console.WriteLine("  IL_" + start.ToString("X4") + ": " + op.Name + " " + operand);
        }
    }

    public static void Main(string[] args)
    {
        Init();
        Assembly asm = Assembly.LoadFile(args[0]);
        string typeName = args[1];
        Type t = asm.GetType(typeName, true);
        BindingFlags flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance | BindingFlags.DeclaredOnly;
        string only = args.Length > 2 ? args[2] : null;
        foreach (MethodBase m in t.GetMethods(flags))
        {
            if (only == null || m.Name == only) DumpMethod(m);
        }
        foreach (ConstructorInfo c in t.GetConstructors(flags))
        {
            if (only == null || c.Name == only) DumpMethod(c);
        }
    }
}


