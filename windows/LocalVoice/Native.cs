using System.Runtime.InteropServices;
namespace LocalVoice;
internal static class Native {
 [DllImport("user32.dll")]internal static extern bool RegisterHotKey(IntPtr window,int id,uint modifiers,uint key);
 [DllImport("user32.dll")]internal static extern bool UnregisterHotKey(IntPtr window,int id);
 [DllImport("user32.dll")]internal static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]internal static extern uint GetClipboardSequenceNumber();
 [DllImport("user32.dll")]static extern short GetAsyncKeyState(int key);
 internal static async Task WaitForModifiers(){for(int i=0;i<40;i++){if(new[]{0x10,0x11,0x12,0x5b,0x5c}.All(k=>(GetAsyncKeyState(k)&0x8000)==0))return;await Task.Delay(50);}throw new InvalidOperationException("Release the shortcut keys, then try again.");}
 [DllImport("user32.dll")]internal static extern bool IsWindow(IntPtr window);
 [DllImport("user32.dll")]static extern uint SendInput(uint count,INPUT[] input,int size);
 [StructLayout(LayoutKind.Sequential)]struct INPUT {public uint type;public INPUTUNION data;}
 [StructLayout(LayoutKind.Explicit)]struct INPUTUNION {[FieldOffset(0)]public KEYBDINPUT keyboard;[FieldOffset(0)]public MOUSEINPUT mouse;}
 [StructLayout(LayoutKind.Sequential)]struct KEYBDINPUT{public ushort key;public ushort scan;public uint flags;public uint time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)]struct MOUSEINPUT{public int x,y;public uint data,flags,time;public UIntPtr extra;}
 internal static void Shortcut(ushort key){INPUT K(ushort k,bool up)=>new(){type=1,data=new(){keyboard=new(){key=k,flags=up?2u:0u}}};var keys=new[]{K(0x11,false),K(key,false),K(key,true),K(0x11,true)};if(SendInput((uint)keys.Length,keys,Marshal.SizeOf<INPUT>())!=keys.Length)throw new InvalidOperationException("Windows blocked the shortcut. Copy or paste manually; elevated apps may require the same privilege level.");}
 internal static string ShortcutName(uint modifiers,uint key)=>string.Join(" + ",new[]{(modifiers&2)!=0?"Ctrl":null,(modifiers&1)!=0?"Alt":null,(modifiers&4)!=0?"Shift":null,(modifiers&8)!=0?"Win":null,((Keys)key).ToString()}.Where(x=>x!=null));
}
internal sealed class HistoryMeter:Control {
 readonly Queue<float> levels=new();public HistoryMeter(){DoubleBuffered=true;Height=80;Dock=DockStyle.Top;}
 public void Push(float value){if(IsDisposed)return;if(InvokeRequired){BeginInvoke(()=>Push(value));return;}levels.Enqueue(value);while(levels.Count>70)levels.Dequeue();Invalidate();}
 protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);var values=levels.ToArray();using var pen=new Pen(Color.FromArgb(126,176,231),3);float width=Width/70f;for(int i=0;i<values.Length;i++){float h=Math.Max(2,Math.Min(Height-4,values[i]*Height*4));float x=Width-(values.Length-i)*width;e.Graphics.DrawLine(pen,x,(Height-h)/2,x,(Height+h)/2);}}
}
internal sealed class RecordingEnterHook:IDisposable {
 delegate IntPtr Hook(int code,IntPtr message,IntPtr info);readonly Hook callback;IntPtr handle;
 [DllImport("user32.dll",SetLastError=true)]static extern IntPtr SetWindowsHookEx(int id,Hook callback,IntPtr module,uint thread);
 [DllImport("user32.dll")]static extern bool UnhookWindowsHookEx(IntPtr hook);
 [DllImport("user32.dll")]static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]static extern IntPtr GetModuleHandle(string? name);
 public RecordingEnterHook(Action finish){callback=(code,message,info)=>{if(code>=0&&Marshal.ReadInt32(info)==0x0d){if(message.ToInt64()==0x0100)finish();return new IntPtr(1);}return CallNextHookEx(handle,code,message,info);};handle=SetWindowsHookEx(13,callback,GetModuleHandle(null),0);if(handle==IntPtr.Zero)throw new InvalidOperationException("Could not register Enter to finish recording. Use the dictation shortcut again.");}
 public void Dispose(){if(handle!=IntPtr.Zero){UnhookWindowsHookEx(handle);handle=IntPtr.Zero;}}
}
internal sealed class InsertionTarget {
 readonly IntPtr window;readonly int[] identity;readonly int process;
 InsertionTarget(IntPtr window,int[] identity,int process){this.window=window;this.identity=identity;this.process=process;}
 public static InsertionTarget? Capture(IntPtr ownWindow){try{var window=Native.GetForegroundWindow();if(window==IntPtr.Zero||window==ownWindow)return null;var focused=System.Windows.Automation.AutomationElement.FocusedElement;if(focused==null||focused.Current.IsPassword||!focused.Current.IsKeyboardFocusable||!focused.Current.IsEnabled)return null;
  // Editable controls expose ValuePattern or an editable document. Other focus targets stay clipboard-only.
  bool editable=focused.TryGetCurrentPattern(System.Windows.Automation.ValuePattern.Pattern,out var pattern)&&pattern is System.Windows.Automation.ValuePattern value&&!value.Current.IsReadOnly;
  if(!editable)return null;return new(window,focused.GetRuntimeId(),focused.Current.ProcessId);
 }catch(System.Windows.Automation.ElementNotAvailableException){return null;}catch(InvalidOperationException){return null;}catch(UnauthorizedAccessException){return null;}catch(System.Runtime.InteropServices.COMException){return null;}}
 public bool StillFocused(){var now=Capture(IntPtr.Zero);return now!=null&&now.window==window&&Native.GetForegroundWindow()==window&&now.process==process&&now.identity.SequenceEqual(identity);}
}
