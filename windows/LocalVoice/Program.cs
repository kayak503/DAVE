namespace LocalVoice;
internal static class Program {
 [STAThread]static void Main(){ApplicationConfiguration.Initialize();Application.ThreadException+=(_,e)=>MessageBox.Show(e.Exception.Message,"DAVE",MessageBoxButtons.OK,MessageBoxIcon.Error);Application.Run(new MainForm());}
}
