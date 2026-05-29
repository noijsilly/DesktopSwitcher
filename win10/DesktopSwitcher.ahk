#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode("Input")
SetWorkingDir(A_ScriptDir)

; ======================================================================
; 0. 权限提升（解决 Hyper-V、任务管理器等高权限窗口下热键失效的问题）
; ======================================================================
if not (A_IsAdmin || RegExMatch(DllCall("GetCommandLine", "str"), " /restart(?!\S)")) {
    try {
        if A_IsCompiled
            Run('*RunAs "' A_ScriptFullPath '" /restart')
        else
            Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    }
    ExitApp()
}

; ======================================================================
; 1. 核心库引入与全局配置
; ======================================================================
#Include VD.ahk

global MaxDesktops := 9
global IniPath := A_ScriptDir . "\DesktopNames.ini"

; --- 动画相关全局变量 ---
global FadeOpacity := 0       ; HUD 当前透明度
global FadeTarget := 230      ; HUD 目标最大透明度

; ======================================================================
; 2. UI 界面初始化：屏幕中央 HUD 弹窗
; ======================================================================
A_TrayMenu.Delete() 
A_TrayMenu.Add("退出 Desktop Switcher", (*) => ExitApp()) 
A_IconTip := "Desktop Switcher (Loading...)" 

global HUD := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale") 
HUD.BackColor := "252525" 

HUD.SetFont("s18 w500 cWhite", "Microsoft YaHei") 
global HUDText := HUD.Add("Text", "x0 y0 w320 h64 0x201 BackgroundTrans", "Desktop") 

; 初始化为完全透明
WinSetTransparent(0, HUD.Hwnd) 

UpdateUI()

; ======================================================================
; 3. 热键绑定 (作用域限定：任务栏 或 屏幕上方 10%)
; ======================================================================
#HotIf IsHoveringTriggerArea()

    ; --- [基础跳转] 切换到指定桌面 (Ctrl + 1~9) ---
    ^1::SwitchTo(1)
    ^2::SwitchTo(2)
    ^3::SwitchTo(3)
    ^4::SwitchTo(4)
    ^5::SwitchTo(5)
    ^6::SwitchTo(6)
    ^7::SwitchTo(7)
    ^8::SwitchTo(8)
    ^9::SwitchTo(9)

    ; --- [相对跳转] 限边界切换上/下桌面 (不滚动过头) ---
    ^Tab::SwitchNext()
    ^+Tab::SwitchPrev()
    !WheelUp::SwitchPrev()      
    !WheelDown::SwitchNext()    

    ; --- [生命周期] 创建新桌面 (Ctrl + N) ---
    ^n:: {
        oldIdx := VD.getCurrentDesktopNum()
        VD.createDesktop(true) 
        loop 50 {
            if (VD.getCurrentDesktopNum() != oldIdx)
                break
            Sleep(10)
        }
        UpdateUI(VD.getCurrentDesktopNum())
    }

    ; --- [生命周期] 删除当前桌面 (Ctrl + Delete) ---
    ^Delete:: {
        if (VD.getCount() > 1) { 
            oldIdx := VD.getCurrentDesktopNum()
            VD.removeDesktop(oldIdx) 
            loop 50 {
                if (VD.getCurrentDesktopNum() != oldIdx)
                    break
                Sleep(10)
            }
            UpdateUI(VD.getCurrentDesktopNum())
        }
    }

#HotIf

; ======================================================================
; 4. 辅助函数实现 (底层与 UI 逻辑)
; ======================================================================

IsHoveringTriggerArea() {
    try {
        MouseGetPos(,, &hWnd)
        if (hWnd) {
            class := WinGetClass("ahk_id " hWnd)
            if (class = "Shell_TrayWnd" || class = "Shell_SecondaryTrayWnd")
                return true
        }
    }

    oldCoordMode := A_CoordModeMouse
    CoordMode("Mouse", "Screen") 
    MouseGetPos(&mouseX, &mouseY)
    CoordMode("Mouse", oldCoordMode) 

    loop MonitorGetCount() {
        try {
            MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
            if (mouseX >= Left && mouseX <= Right && mouseY >= Top && mouseY <= Bottom) {
                monitorHeight := Bottom - Top      
                relativeY := mouseY - Top          
                if (relativeY <= monitorHeight * 0.10)
                    return true
                break 
            }
        }
    }
    return false
}

; --- 已全面修复：结合 DWM 快捷键视觉动画与 VD 库核心跳转 ---
SwitchTo(targetIndex) {
    if (targetIndex > VD.getCount() || targetIndex > MaxDesktops || targetIndex < 1)
        return
        
    current := VD.getCurrentDesktopNum()
    if (current == targetIndex)
        return

    ; 1. 视觉先导：发送快捷键，骗取系统的 DWM 滑屏渲染效果
    diff := targetIndex - current
    if (diff > 0) {
        loop diff {
            Send("^#{Right}")
            Sleep(5) 
        }
    } else {
        diff := Abs(diff)
        loop diff {
            Send("^#{Left}")
            Sleep(5)
        }
    }
    
    ; 2. 核心补漏：调用 VD 核心库接口执行绝对跳转，确保桌面必定切换过去
    VD.goToDesktopNum(targetIndex)
    
    ; 3. 高频异步守候状态同步
    loop 30 {
        if (VD.getCurrentDesktopNum() == targetIndex)
            break
        Sleep(10)
    }
    
    ; 4. 刷新中央 HUD 提示
    UpdateUI(targetIndex) 
}

; --- 向右切换，触底直接拦截不再循环 ---
SwitchNext() {
    current := VD.getCurrentDesktopNum()
    total := VD.getCount()
    nextIdx := current + 1
    if (nextIdx > total)
        return 
    SwitchTo(nextIdx)
}

; --- 向左切换，触顶直接拦截不再循环 ---
SwitchPrev() {
    current := VD.getCurrentDesktopNum()
    prevIdx := current - 1
    if (prevIdx < 1)
        return 
    SwitchTo(prevIdx)
}

TruncateString(str, maxLength := 12) {
    if (StrLen(str) > maxLength) {
        return SubStr(str, 1, maxLength) . "..."
    }
    return str
}

GetDesktopNameFromIni(index) {
    if !FileExist(IniPath) {
        loop MaxDesktops {
            IniWrite("桌面 " . A_Index, IniPath, "Names", String(A_Index))
        }
    }
    return IniRead(IniPath, "Names", String(index), "桌面 " . index)
}

; --- UI 渐隐渐现核心控制 ---
UpdateUI(targetIdx := 0) {
    currentIdx := (targetIdx == 0) ? VD.getCurrentDesktopNum() : targetIdx
    rawName := GetDesktopNameFromIni(currentIdx)
    global A_IconTip := rawName

    HUDText.Value := "❖  " . TruncateString(rawName, 12)
    
    SetTimer(StartFadeOut, 0)
    SetTimer(DoFadeOut, 0)
    
    HUD.Show("NoActivate xCenter yCenter w320 h64")
    WinSetRegion("0-0 w320 h64 R16-16", HUD.Hwnd)

    SetTimer(DoFadeIn, 15)
}

DoFadeIn() {
    global FadeOpacity, FadeTarget
    if (FadeOpacity < FadeTarget) {
        FadeOpacity += 30  
        if (FadeOpacity > FadeTarget)
            FadeOpacity := FadeTarget
        WinSetTransparent(FadeOpacity, HUD.Hwnd)
    } else {
        SetTimer(DoFadeIn, 0) 
        SetTimer(StartFadeOut, -1000) 
    }
}

StartFadeOut() {
    SetTimer(DoFadeOut, 15) 
}

DoFadeOut() {
    global FadeOpacity
    if (FadeOpacity > 0) {
        FadeOpacity -= 20  
        if (FadeOpacity < 0)
            FadeOpacity := 0
        WinSetTransparent(FadeOpacity, HUD.Hwnd)
    } else {
        SetTimer(DoFadeOut, 0) 
        HUD.Hide()             
    }
}
