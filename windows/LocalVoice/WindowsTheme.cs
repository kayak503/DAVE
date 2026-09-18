namespace LocalVoice;

// Keep native keyboard, focus and accessibility behavior; use one palette everywhere.
internal static class WindowsTheme
{
 public static Color Surface => SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(248,250,253);
 public static Color Ink => SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(28,39,56);
 public static Color Accent => SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(35,91,187);
 public static void Apply(Control root)
 {
  root.BackColor=Surface;root.ForeColor=Ink;
  foreach(Control control in root.Controls)
  {
   Apply(control);
   if(control is Button button)
   {
    button.UseVisualStyleBackColor=false;button.FlatStyle=FlatStyle.Flat;
    button.BackColor=SystemColors.Window;button.ForeColor=Ink;
    button.FlatAppearance.BorderColor=SystemInformation.HighContrast?SystemColors.WindowText:Color.FromArgb(198,208,222);
    button.FlatAppearance.MouseOverBackColor=SystemInformation.HighContrast?SystemColors.Highlight:Color.FromArgb(229,238,252);
    button.FlatAppearance.MouseDownBackColor=SystemInformation.HighContrast?SystemColors.Highlight:Color.FromArgb(210,225,248);
    button.Padding=new Padding(12,6,12,6);button.MinimumSize=new Size(88,38);
    button.AutoSize=true;button.AutoSizeMode=AutoSizeMode.GrowAndShrink;button.Margin=new Padding(0,0,8,8);
   }
   if(control is TextBoxBase or ListBox or ComboBox or NumericUpDown)control.BackColor=SystemColors.Window;
   if(control is DataGridView grid)
   {
    grid.EnableHeadersVisualStyles=false;grid.BackgroundColor=SystemColors.Window;
    grid.GridColor=SystemInformation.HighContrast?SystemColors.WindowText:Color.FromArgb(224,230,239);
    grid.ColumnHeadersDefaultCellStyle.BackColor=Surface;grid.ColumnHeadersDefaultCellStyle.ForeColor=Ink;
    grid.ColumnHeadersDefaultCellStyle.SelectionBackColor=Surface;grid.ColumnHeadersDefaultCellStyle.SelectionForeColor=Ink;
    grid.ColumnHeadersDefaultCellStyle.Padding=new Padding(8);grid.ColumnHeadersHeightSizeMode=DataGridViewColumnHeadersHeightSizeMode.AutoSize;
    grid.DefaultCellStyle.BackColor=SystemColors.Window;grid.DefaultCellStyle.ForeColor=Ink;
    grid.DefaultCellStyle.SelectionBackColor=Accent;grid.DefaultCellStyle.SelectionForeColor=SystemColors.HighlightText;
    grid.DefaultCellStyle.Padding=new Padding(8);grid.DefaultCellStyle.WrapMode=DataGridViewTriState.True;
    grid.AutoSizeRowsMode=DataGridViewAutoSizeRowsMode.DisplayedCells;
    grid.CellBorderStyle=DataGridViewCellBorderStyle.SingleHorizontal;
   }
  }
 }
}

internal sealed class WorkspaceNavigation:UserControl
{
 readonly FlowLayoutPanel navigation=new(){Dock=DockStyle.Left,Width=160,Padding=new Padding(12,24,8,12),FlowDirection=FlowDirection.TopDown,WrapContents=false};
 readonly Panel content=new(){Dock=DockStyle.Fill};
 readonly List<Panel> pages=new();readonly List<Button> buttons=new();int selected;
 public WorkspaceNavigation()
 {
  Dock=DockStyle.Fill;Controls.Add(content);Controls.Add(navigation);
  navigation.Controls.Add(new Label{Text="DAVE",AutoSize=true,Font=new Font("Segoe UI",20,FontStyle.Bold),Margin=new Padding(8,0,0,4)});
  navigation.Controls.Add(new Label{Text="Private voice tools",AutoSize=true,MaximumSize=new Size(132,0),Margin=new Padding(8,0,0,20)});
 }
 public Panel AddPage(string title)
 {
  int index=pages.Count;var page=new Panel{Dock=DockStyle.Fill,Padding=new Padding(24),Visible=index==0};pages.Add(page);content.Controls.Add(page);
  var button=new Button{Text=title,Width=136,Height=44,TextAlign=ContentAlignment.MiddleLeft,AccessibleName=title};
  button.Click+=(_,_)=>SelectedIndex=index;buttons.Add(button);navigation.Controls.Add(button);return page;
 }
 public int SelectedIndex
 {
  get=>selected;
  set{if(value<0||value>=pages.Count)return;selected=value;for(int i=0;i<pages.Count;i++)pages[i].Visible=i==value;pages[value].BringToFront();RefreshSelection();}
 }
 public void RefreshSelection()
 {
  for(int i=0;i<buttons.Count;i++){var b=buttons[i];b.AutoSize=false;b.Width=navigation.ClientSize.Width-navigation.Padding.Horizontal;b.BackColor=i==selected?WindowsTheme.Accent:SystemColors.Window;b.ForeColor=i==selected?SystemColors.HighlightText:WindowsTheme.Ink;}
 }
}
