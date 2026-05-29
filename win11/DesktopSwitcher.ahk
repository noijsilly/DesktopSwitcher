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
; 1. 底层 DLL 加载与指针映射 (完全对齐官方示例)
; ======================================================================
global DllPath := A_ScriptDir "\VirtualDesktopAccessor.dll"
global hVDA := DllCall("LoadLibrary", "Str", DllPath, "Ptr")

if !hVDA {
    MsgBox("无法加载 VirtualDesktopAccessor.dll，请确保它与脚本在同一目录下！", "错误", 16)
    ExitApp()
}

; 动态捕获函数指针
global GetDesktopCountProc             := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetDesktopCount", "Ptr")
global GoToDesktopNumberProc           := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GoToDesktopNumber", "Ptr")
global GetCurrentDesktopNumberProc     := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetCurrentDesktopNumber", "Ptr")
global MoveWindowToDesktopNumberProc   := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "MoveWindowToDesktopNumber", "Ptr")
global GetDesktopNameProc              := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "GetDesktopName", "Ptr")
global SetDesktopNameProc              := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "SetDesktopName", "Ptr")
global CreateDesktopProc               := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "CreateDesktop", "Ptr")
global RemoveDesktopProc               := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "RemoveDesktop", "Ptr")
global RegisterPostMessageHookProc     := DllCall("GetProcAddress", "Ptr", hVDA, "AStr", "RegisterPostMessageHook", "Ptr")

; ======================================================================
; 2. 规范的 AHK v2 全局强类型接口函数封装 (1基索引转换 - 完全保留原样)
; ======================================================================
GetDesktopCount() {
    return DllCall(GetDesktopCountProc, "Int")
}

GetCurrentDesktopNum() {
    return DllCall(GetCurrentDesktopNumberProc, "Int") + 1
}

GoToDesktopNum(num) {
    DllCall(GoToDesktopNumberProc, "Int", num - 1, "Int")
}

MoveWindowToDesktopNum(hwnd, num) {
    DllCall(MoveWindowToDesktopNumberProc, "Ptr", hwnd, "Int", num - 1, "Int")
}

CreateDesktop() {
    DllCall(CreateDesktopProc, "Int")
}

RemoveDesktop(removeNum, fallbackNum) {
    DllCall(RemoveDesktopProc, "Int", removeNum - 1, "Int", fallbackNum - 1, "Int")
}

GetDesktopName(num) {
    utf8_buffer := Buffer(1024, 0)
    DllCall(GetDesktopNameProc, "Int", num - 1, "Ptr", utf8_buffer, "Ptr", utf8_buffer.Size, "Int")
    name := StrGet(utf8_buffer, "UTF-8")
    return (name != "") ? name : "桌面 " num
}

SetDesktopName(num, name) {
    name_utf8 := Buffer(1024, 0)
    StrPut(name, name_utf8, "UTF-8")
    DllCall(SetDesktopNameProc, "Int", num - 1, "Ptr", name_utf8, "Int")
}

; 设定桌面最大数量限制
global MaxDesktops := 9

; --- 动画相关全局变量 ---
global FadeOpacity := 0       ; HUD 当前透明度
global FadeTarget := 230      ; HUD 目标最大透明度

; ======================================================================
; 3. UI 界面初始化：系统托盘与屏幕中央 HUD
; ======================================================================
A_TrayMenu.Delete() 
A_TrayMenu.Add("退出 Desktop Switcher", (*) => ExitApp()) 
A_IconTip := "Desktop Switcher (Loading...)" 

; 适配 16 字长，将窗口宽度从 400 微调回极简贴合的 360 像素
global HUD := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale") 
HUD.BackColor := "252525" 

HUD.SetFont("s18 w500 cWhite", "Microsoft YaHei") 
global HUDText := HUD.Add("Text", "x0 y0 w360 h64 0x201 BackgroundTrans", "Desktop") 

; 初始化为完全透明
WinSetTransparent(0, HUD.Hwnd) 

UpdateUI(0)

; ======================================================================
; 4. 热键绑定 (作用域限定：任务栏 或 屏幕上方 10%)
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

    ; --- [相对跳转] 限边界切换上/下桌面 (无修饰键免 Alt 纯滚轮触发) ---
    ^Tab::SwitchNext()
    ^+Tab::SwitchPrev()
    WheelUp::SwitchPrev()      
    WheelDown::SwitchNext()    

    ; --- [生命周期] 创建新桌面 (Ctrl + N) ---
    ^n:: {
        oldIdx := GetCurrentDesktopNum()
        CreateDesktop() 
        
        loop 50 {
            if (GetCurrentDesktopNum() != oldIdx)
                break
            Sleep(10)
        }
        UpdateUI(GetCurrentDesktopNum())
    }

    ; --- [生命周期] 删除当前桌面 (Ctrl + Delete) ---
    ^Delete:: {
        total := GetDesktopCount()
        if (total > 1) { 
            oldIdx := GetCurrentDesktopNum()
            fallbackIdx := (oldIdx == 1) ? 1 : (oldIdx - 1)
            
            RemoveDesktop(oldIdx, fallbackIdx) 
            
            loop 50 {
                if (GetCurrentDesktopNum() != oldIdx)
                    break
                Sleep(10)
            }
            UpdateUI(GetCurrentDesktopNum())
        }
    }

    ; --- [状态修改] 重命名当前桌面 (F2) ---
    F2:: {
        currentIdx := GetCurrentDesktopNum()
        currentName := GetDesktopName(currentIdx)
        
        IB := InputBox("请输入新的桌面名称：", "重命名当前桌面", "w300", currentName)
        
        if (IB.Result = "OK") {
            SetDesktopName(currentIdx, IB.Value)
            UpdateUI(currentIdx) 
        }
    }

#HotIf

; ======================================================================
; 5. 核心业务与 UI 渲染函数实现
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

SwitchTo(targetIndex) {
    if (targetIndex > GetDesktopCount() || targetIndex > MaxDesktops || targetIndex < 1)
        return
    
    current := GetCurrentDesktopNum()
    if (current == targetIndex)
        return

    if (GetKeyState("LButton", "P")) {
        try {
            activeHwnd := WinGetID("A")
            if (activeHwnd)
                MoveWindowToDesktopNum(activeHwnd, targetIndex)
        }
    }
    
    GoToDesktopNum(targetIndex)
    UpdateUI(targetIndex) 
}

SwitchNext() {
    current := GetCurrentDesktopNum()
    total := GetDesktopCount()
    nextIdx := current + 1
    if (nextIdx > total)
        return 
    SwitchTo(nextIdx)
}

SwitchPrev() {
    current := GetCurrentDesktopNum()
    prevIdx := current - 1
    if (prevIdx < 1)
        return 
    SwitchTo(prevIdx)
}

; --- 已调整：精准放宽截断限制到 16 个字符 ---
TruncateString(str, maxLength := 16) {
    if (StrLen(str) > maxLength) {
        return SubStr(str, 1, maxLength) . "..."
    }
    return str
}

UpdateUI(targetIdx) {
    local currentIdx := 0
    if (targetIdx = 0) {
        currentIdx := GetCurrentDesktopNum()
    } else {
        currentIdx := targetIdx
    }

    rawName := GetDesktopName(currentIdx)
    global A_IconTip := rawName
    
    ; 渲染带图标的 16 字长文本
    HUDText.Value := "❖  " . TruncateString(rawName, 16)
    
    SetTimer(StartFadeOut, 0)
    SetTimer(DoFadeOut, 0)
    
    ; 居中显示 360 像素宽度的精致弹窗
    HUD.Show("NoActivate xCenter yCenter w360 h64")
    WinSetRegion("0-0 w360 h64 R16-16", HUD.Hwnd)
    
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

; ======================================================================
; 6. 注册系统底层虚拟桌面切换通知事件 (保持托盘同步更新 - 完全保留原样)
; ======================================================================
DllCall(RegisterPostMessageHookProc, "Ptr", A_ScriptHwnd, "Int", 0x1400 + 30, "Int")
OnMessage(0x1400 + 30, OnChangeDesktop)

OnChangeDesktop(wParam, lParam, msg, hwnd) {
    Critical(1)
    newDesktopIdx := lParam + 1
    global A_IconTip := GetDesktopName(newDesktopIdx)
}
