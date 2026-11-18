using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace LoaderCrack
{
    internal static class Program
    {
        private static readonly StringBuilder Trace = new StringBuilder();
        private static readonly object Gate = new object();
        private static string _dir;
        private static string _key = "LOCAL-0000-0000-0000-0000";
        private static bool _testLaunch = false;

        [STAThread]
        private static void Main(string[] args)
        {
            _dir = AppDomain.CurrentDomain.BaseDirectory;

            // ---------------------------------------------------------------
            // Self-update is disabled on purpose.
            //
            // GameLoader.SelfUpdate.Install copies the running executable to
            // "updater.exe" and re-launches it as
            //     updater.exe --apply-loader-update <pid> "<path>" "<request>"
            // Inside that copy Program.Main -> SelfUpdate.HandleArguments runs
            // the apply branch, and every failure ends in the blocking dialog
            //     "Не удалось обновить лоадер. Запустите его снова."
            // The cracked build must never be replaced by the vendor's signed
            // one anyway, so acknowledge the hand-off and exit cleanly instead
            // of letting that branch run.
            // ---------------------------------------------------------------
            if (args.Length > 0 &&
                (string.Equals(args[0], "--apply-loader-update", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(args[0], "--cleanup-loader-update", StringComparison.OrdinalIgnoreCase)))
            {
                Say("self-update args ignored: " + args[0]);
                ClearUpdateReceipt();
                Flush();
                return;
            }

            bool selftest = false;
            bool auto = true;
            bool kill = false;
            bool noElevate = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], "--selftest", StringComparison.OrdinalIgnoreCase)) { selftest = true; auto = false; }
                if (string.Equals(args[i], "--no-auto", StringComparison.OrdinalIgnoreCase)) auto = false;
                if (string.Equals(args[i], "--test-launch", StringComparison.OrdinalIgnoreCase)) _testLaunch = true;
                if (string.Equals(args[i], "--kill", StringComparison.OrdinalIgnoreCase)) kill = true;
                if (string.Equals(args[i], "--no-elevate", StringComparison.OrdinalIgnoreCase)) noElevate = true;
                if (string.Equals(args[i], "--key", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) _key = args[++i];
            }

            string loader = Path.Combine(_dir, "Loader.exe");
            if (!File.Exists(loader))
            {
                Say("Loader.exe not found next to LoaderCrack.exe");
                Flush();
                return;
            }

            if (!selftest && !noElevate && !IsAdmin())
            {
                if (RelaunchElevated(args)) return;
                Say("FATAL: elevation declined - the driver cannot be mapped without an admin token");
                MessageBox.Show(
                    "The cheat runtime needs an elevated token to map its driver.\r\n" +
                    "Elevation was declined, so the overlay would never attach.\r\n\r\n" +
                    "Run start.bat and accept the UAC prompt.",
                    "Loader", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            Say("admin=" + IsAdmin());
            if (!IsAdmin() && !noElevate && !selftest)
            {
                Say("FATAL: still not elevated, aborting before driver map");
                return;
            }

            // A receipt left behind by an applied update makes SelfUpdate.Check
            // POST /api/v1/loader-update/complete on every start. Drop it so
            // the update machine never wakes up.
            ClearUpdateReceipt();

            if (kill)
            {
                Process[] all = Process.GetProcessesByName("LoaderCrack");
                for (int i = 0; i < all.Length; i++)
                {
                    if (all[i].Id != Process.GetCurrentProcess().Id)
                    {
                        try { all[i].Kill(); Say("killed " + all[i].Id); } catch { }
                    }
                }
                return;
            }

            try
            {
                byte[] image = File.ReadAllBytes(loader);
                image = PatchIntegrity(image);
                Assembly asm = Assembly.Load(image);
                Say("loaded " + asm.FullName);

                Type cfg = asm.GetType("GameLoader.Config", true);
                FieldInfo servers = cfg.GetField("Servers",
                    BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                string[] current = (string[])servers.GetValue(null);
                Say("servers was: " + string.Join(", ", current ?? new string[0]));
                string overrideList = Environment.GetEnvironmentVariable("LOADER_SERVERS");
                if (!string.IsNullOrEmpty(overrideList))
                {
                    servers.SetValue(null, overrideList.Split(','));
                    Say("servers set (env): " + overrideList);
                }
                else
                {
                    servers.SetValue(null, new string[] { "http://127.0.0.1:8765" });
                    Say("servers set: http://127.0.0.1:8765");
                }

                SeedSavedKey(asm);

                if (selftest)
                {
                    SelfTest(asm);
                    Flush();
                    return;
                }

                if (auto)
                {
                    StartAutoLogin();
                }

                Type prog = asm.GetType("GameLoader.Program", true);
                MethodInfo main = prog.GetMethod("Main",
                    BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                Say("invoking Program.Main");
                Flush();
                main.Invoke(null, new object[] { new string[0] });
            }
            catch (TargetInvocationException tie)
            {
                Say("ERROR " + (tie.InnerException != null ? tie.InnerException.ToString() : tie.ToString()));
            }
            catch (Exception ex)
            {
                Say("ERROR " + ex);
            }
            Flush();
        }

        private static bool IsAdmin()
        {
            try
            {
                WindowsIdentity id = WindowsIdentity.GetCurrent();
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        private static bool RelaunchElevated(string[] args)
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < args.Length; i++)
                {
                    if (i > 0) sb.Append(' ');
                    sb.Append('"').Append(args[i]).Append('"');
                }
                ProcessStartInfo psi = new ProcessStartInfo(Application.ExecutablePath, sb.ToString());
                psi.UseShellExecute = true;
                psi.Verb = "runas";
                psi.WorkingDirectory = _dir;
                Process.Start(psi);
                Say("relaunching elevated (UAC)");
                return true;
            }
            catch (Exception ex)
            {
                Say("elevation cancelled: " + ex.Message);
                return false;
            }
        }

        private static byte[] PatchIntegrity(byte[] image)
        {
            try
            {
                Assembly scratch = Assembly.Load((byte[])image.Clone());
                Type t = scratch.GetType("GameLoader.ReleaseIntegrity");
                if (t == null) { Say("patch: ReleaseIntegrity missing"); return image; }
                string[] names = new string[] { "Verify", "VerifyEnvelope", "ValidateDigest" };
                for (int i = 0; i < names.Length; i++)
                {
                    MethodInfo m = t.GetMethod(names[i],
                        BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                    if (m == null) { Say("patch: " + names[i] + " missing"); continue; }
                    byte[] il = m.GetMethodBody().GetILAsByteArray();
                    int count = 0;
                    int found = -1;
                    for (int o = 0; o + il.Length <= image.Length; o++)
                    {
                        bool hit = true;
                        for (int k = 0; k < il.Length; k++)
                        {
                            if (image[o + k] != il[k]) { hit = false; break; }
                        }
                        if (hit) { count++; if (found < 0) found = o; }
                    }
                    if (count != 1) { Say("patch: " + names[i] + " hits=" + count + " (skipped)"); continue; }
                    int header = found - 12;
                    if (header > 0 && (image[header] & 0x03) == 0x03 && image[header + 1] == 0x30 && (header + 12) == found)
                    {
                        image[header] = 0x06;
                        image[header + 1] = 0x2A;
                        Say("patch: " + names[i] + " neutralized at 0x" + header.ToString("X"));
                    }
                    else
                    {
                        Say("patch: " + names[i] + " fat header mismatch");
                    }
                }
            }
            catch (Exception ex)
            {
                Say("patch: error " + ex.Message);
            }
            return image;
        }
        private static void ClearUpdateReceipt()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k =
                    Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                        @"Software\Hidden\Loader", true))
                {
                    if (k != null) k.DeleteValue("LoaderUpdateReceipt", false);
                }
            }
            catch { }
        }

        private static void SeedSavedKey(Assembly asm)
        {
            try
            {
                Type store = asm.GetType("GameLoader.RegistryKeyStore");
                if (store == null) return;
                FieldInfo rem = store.GetField("Remembered",
                    BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
                MethodInfo save = store.GetMethod("Save",
                    BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                object inst = rem == null ? null : rem.GetValue(null);
                if (save == null || inst == null) return;
                object ok = save.Invoke(inst, new object[] { _key });
                Say("registry seed: " + ok);
                Say("registry key seeded: " + _key);
            }
            catch (Exception ex)
            {
                Say("registry seed failed: " + (ex.InnerException != null ? ex.InnerException.Message : ex.Message));
            }
        }

        private static void StartAutoLogin()
        {
            Thread t = new Thread(AutoLogin);
            t.IsBackground = true;
            t.Start();
        }

        private static void AutoLogin()
        {
            Form host = null;
            object core = null;
            for (int i = 0; i < 60 && host == null; i++)
            {
                Thread.Sleep(400);
                try { host = FindHost(); } catch { }
            }
            if (host == null) { Say("auto: host not found"); return; }
            Say("auto: host found " + host.GetType().FullName);

            for (int i = 0; i < 40 && core == null; i++)
            {
                try { core = (object)host.Invoke(new Func<object>(delegate { return FindCore(host); })); } catch { }
                if (core == null) Thread.Sleep(400);
            }
            if (core == null) { Say("auto: core not found"); return; }
            Say("auto: core ok " + core.GetType().FullName);

            for (int attempt = 0; attempt < 6; attempt++)
            {
                Thread.Sleep(1500);
                ExecAsync(host, core, FillJs());
                string r = WaitResult(10000);
                Say("auto: exec " + r);
                Thread.Sleep(2500);
                ExecAsync(host, core, ProbeJs());
                string st = WaitResult(10000);
                Say("auto: state " + st);
                if (st.IndexOf("main\\\":true") >= 0) { Say("auto: login done"); if (_testLaunch) TestLaunch(host, core); return; }
            }
            Say("auto: submitted, check the window");
        }
        private static void TestLaunch(Form host, object core)
        {
            ExecAsync(host, core,
                "(function(){var b=document.querySelector('.card .btn-play');" +
                "if(!b) return 'no-btn';b.click();return 'clicked';})()");
            Say("launch: click " + WaitResult(10000));
            Thread.Sleep(6000);
            ExecAsync(host, core,
                "(function(){var m=document.getElementById('sbMsg');" +
                "var t=document.getElementById('toast');" +
                "return JSON.stringify({msg:m?m.textContent:'',toast:t?t.textContent:'',cls:t?t.className:''});})()");
            Say("launch: result " + WaitResult(10000));
        }
        private static string FillJs()
        {
            return
                "(function(){var f=document.getElementById('keyField');" +
                "if(!f) return 'no-field';" +
                "f.value=" + JsStr(_key) + ";" +
                "f.dispatchEvent(new Event('input',{bubbles:true}));" +
                "var form=document.getElementById('keyForm');" +
                "form.dispatchEvent(new Event('submit',{cancelable:true,bubbles:true}));" +
                "return 'submitted';})()";
        }

        private static string ProbeJs()
        {
            return
                "(function(){var cards=document.querySelectorAll('.card').length;" +
                "var keyEl=document.getElementById('keyMasked');" +
                "var main=document.getElementById('main');" +
                "var login=document.getElementById('login');" +
                "return JSON.stringify({cards:cards," +
                "key:keyEl?keyEl.textContent:''," +
                "main:main?(!main.hidden&&main.style.display!=='none'):false," +
                "login:login?(!login.hidden&&login.style.display!=='none'):false});})()";
        }

        private static Form FindHost()
        {
            FormCollection forms = Application.OpenForms;
            for (int i = 0; i < forms.Count; i++)
            {
                Form f = forms[i];
                string n = f.GetType().FullName;
                if (n != null && n.EndsWith("HostForm")) return f;
            }
            return null;
        }

        private static object FindCore(Form host)
        {
            Type t = host.GetType();
            FieldInfo[] fields = t.GetFields(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            object control = null;
            for (int i = 0; i < fields.Length; i++)
            {
                object v = null;
                try { v = fields[i].GetValue(host); } catch { continue; }
                if (v == null) continue;
                string n = v.GetType().FullName;
                if (n == null) continue;
                if (n == "Microsoft.Web.WebView2.Core.CoreWebView2") return v;
                if (n.StartsWith("Microsoft.Web.WebView2.WinForms.WebView2")) control = v;
            }
            if (control != null)
            {
                PropertyInfo p = control.GetType().GetProperty("CoreWebView2");
                if (p != null) return p.GetValue(control, null);
            }
            return null;
        }

        private static volatile string _last = null;

        private static void ExecAsync(Form host, object core, string js)
        {
            _last = null;
            host.BeginInvoke(new Action(delegate
            {
                try
                {
                    MethodInfo m = core.GetType().GetMethod("ExecuteScriptAsync", new Type[] { typeof(string) });
                    if (m == null) { _last = "<no ExecuteScriptAsync>"; return; }
                    object task = m.Invoke(core, new object[] { js });
                    Task t = task as Task;
                    if (t == null) { _last = "<not a task>"; return; }
                    t.ContinueWith(delegate(Task tt)
                    {
                        try
                        {
                            object res = tt.GetType().GetProperty("Result").GetValue(tt, null);
                            _last = res == null ? "<null>" : res.ToString();
                        }
                        catch (Exception ex)
                        {
                            Exception e2 = ex.InnerException != null ? ex.InnerException : ex;
                            _last = "<error " + e2.Message + ">";
                        }
                    });
                }
                catch (Exception ex)
                {
                    Exception e2 = ex.InnerException != null ? ex.InnerException : ex;
                    _last = "<start error " + e2.Message + ">";
                }
            }));
        }

        private static string WaitResult(int ms)
        {
            int waited = 0;
            while (_last == null && waited < ms) { Thread.Sleep(100); waited += 100; }
            return _last == null ? "<timeout>" : _last;
        }
        private static string ExecCore(object core, string js)
        {
            try
            {
                MethodInfo m = core.GetType().GetMethod("ExecuteScriptAsync", new Type[] { typeof(string) });
                if (m == null) return "<no ExecuteScriptAsync>";
                object task = m.Invoke(core, new object[] { js });
                MethodInfo wait = task.GetType().GetMethod("Wait", new Type[] { typeof(int) });
                if (wait != null) wait.Invoke(task, new object[] { 6000 });
                object result = task.GetType().GetProperty("Result").GetValue(task, null);
                return result == null ? "<null>" : result.ToString();
            }
            catch (Exception ex)
            {
                Exception e = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex;
                return "<exec error " + e.Message + ">";
            }
        }

        private static string JsStr(string s)
        {
            StringBuilder sb = new StringBuilder("'");
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '\'' || c == '\\') sb.Append('\\');
                sb.Append(c);
            }
            sb.Append('\'');
            return sb.ToString();
        }

        private static void SelfTest(Assembly asm)
        {
            Type apiType = asm.GetType("GameLoader.Api", true);
            object api = Activator.CreateInstance(apiType, true);
            MethodInfo auth = apiType.GetMethod("Authenticate",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            Say("calling Api.Authenticate");
            object task = auth.Invoke(api, new object[] { _key });
            Wait(task);
            Dump("auth", task.GetType().GetProperty("Result").GetValue(task, null));

            MethodInfo me = apiType.GetMethod("Me",
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            object t2 = me.Invoke(api, new object[0]);
            Wait(t2);
            Dump("me", t2.GetType().GetProperty("Result").GetValue(t2, null));
        }

        private static void Wait(object task)
        {
            MethodInfo wait = task.GetType().GetMethod("Wait", new Type[] { typeof(int) });
            if (wait != null) wait.Invoke(task, new object[] { 8000 });
            Thread.Sleep(150);
        }

        private static void Dump(string label, object result)
        {
            if (result == null) { Say(label + ": <null>"); return; }
            IDictionary dict = result as IDictionary;
            if (dict != null)
            {
                Say(label + ": dict count=" + dict.Count);
                foreach (DictionaryEntry e in dict)
                {
                    string v = e.Value == null ? "null" : e.Value.ToString();
                    if (v.Length > 240) v = v.Substring(0, 240) + "...";
                    Say("  " + e.Key + " = " + v);
                }
                return;
            }
            Say(label + ": " + result.GetType().FullName + " = " + result);
        }

        private static void Say(string line)
        {
            lock (Gate) { Trace.Append(DateTime.Now.ToString("HH:mm:ss")).Append(' ').Append(line).Append("\r\n"); Flush(); }
        }

        private static void Flush()
        {
            try { lock (Gate) File.WriteAllText(Path.Combine(_dir, "loader_crack.log"), Trace.ToString()); }
            catch { }
        }
    }
}














