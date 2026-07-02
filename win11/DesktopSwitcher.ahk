#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode("Input")
SetWorkingDir(A_ScriptDir)

; ======================================================================
; 0. 权限提升
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
; 1. 底层 DLL 加载与指针映射
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
; 2. 接口函数封装 (1基索引)
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

; ======================================================================
; 2.5 桌面历史记录
; ======================================================================
global gCurrentDesktop := GetCurrentDesktopNum()
global gPreviousDesktop := gCurrentDesktop

; --- 动画相关全局变量 ---
global FadeOpacity := 0
global FadeTarget := 230

; ======================================================================
; 3. UI 界面初始化
; ======================================================================
A_TrayMenu.Delete() 
A_TrayMenu.Add("退出 Desktop Switcher", (*) => ExitApp()) 
A_IconTip := "Desktop Switcher (Loading...)" 

global HUD := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale") 
HUD.BackColor := "252525" 

HUD.SetFont("s18 w500 cWhite", "Microsoft YaHei") 
global HUDText := HUD.Add("Text", "x0 y0 w360 h64 0x201 BackgroundTrans", "Desktop") 

WinSetTransparent(0, HUD.Hwnd) 

UpdateUI(gCurrentDesktop)

; ======================================================================
; 4. 配置文件读取（是否启用顶部触发区域）
; ======================================================================
global gEnableTopArea := false
configFile := A_ScriptDir "\DesktopSwitcher.ini"
if FileExist(configFile) {
    try {
        gEnableTopArea := IniRead(configFile, "Settings", "EnableTopArea", "false") = "true"
    }
} else {
    ; 创建默认配置文件（默认关闭顶部触发）
    iniContent := "[Settings]`nEnableTopArea=false"
    FileAppend(iniContent, configFile)
}

; ======================================================================
; 5. 触发条件判断（任务栏 或 屏幕顶部（可配置））
; ======================================================================
IsTriggerActive() {
    ; 1) 检查鼠标是否在任务栏上
    static taskbarClasses := ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"]
    try {
        MouseGetPos(,, &hWnd)
        if (hWnd) {
            class := WinGetClass("ahk_id " hWnd)
            for cls in taskbarClasses {
                if (class = cls)
                    return true
            }
        }
    }

    ; 2) 如果配置允许，检查鼠标是否在屏幕顶部 10% 区域内
    if (gEnableTopArea) {
        oldCoordMode := A_CoordModeMouse
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mouseX, &mouseY)
        CoordMode("Mouse", oldCoordMode)
        loop MonitorGetCount() {
            try {
                MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
                if (mouseX >= Left && mouseX <= Right && mouseY >= Top && mouseY <= Bottom) {
                    monitorHeight := Bottom - Top
                    if (mouseY - Top <= monitorHeight * 0.10)
                        return true
                    break
                }
            }
        }
    }
    return false
}

; ======================================================================
; 6. 热键绑定（仅当触发条件满足时生效）
; ======================================================================
#HotIf IsTriggerActive()

    ; --- 基础跳转 Ctrl+1~9 ---
    ^1::SwitchTo(1)
    ^2::SwitchTo(2)
    ^3::SwitchTo(3)
    ^4::SwitchTo(4)
    ^5::SwitchTo(5)
    ^6::SwitchTo(6)
    ^7::SwitchTo(7)
    ^8::SwitchTo(8)
    ^9::SwitchTo(9)

    ; --- 相对跳转 ---
    ^Tab::SwitchNext()
    ^+Tab::SwitchPrev()
    WheelUp::SwitchPrev()
    WheelDown::SwitchNext()

    ; --- 快速往返 Alt+Tab ---
    !Tab::SwitchToPreviousDesktop()

    ; --- ★ 首字母跳转 Ctrl+A~Z ★ ---
    ^a::SwitchToByLetter("a")
    ^b::SwitchToByLetter("b")
    ^c::SwitchToByLetter("c")
    ^d::SwitchToByLetter("d")
    ^e::SwitchToByLetter("e")
    ^f::SwitchToByLetter("f")
    ^g::SwitchToByLetter("g")
    ^h::SwitchToByLetter("h")
    ^i::SwitchToByLetter("i")
    ^j::SwitchToByLetter("j")
    ^k::SwitchToByLetter("k")
    ^l::SwitchToByLetter("l")
    ^m::SwitchToByLetter("m")
    ^n::SwitchToByLetter("n")
    ^o::SwitchToByLetter("o")
    ^p::SwitchToByLetter("p")
    ^q::SwitchToByLetter("q")
    ^r::SwitchToByLetter("r")
    ^s::SwitchToByLetter("s")
    ^t::SwitchToByLetter("t")
    ^u::SwitchToByLetter("u")
    ^v::SwitchToByLetter("v")
    ^w::SwitchToByLetter("w")
    ^x::SwitchToByLetter("x")
    ^y::SwitchToByLetter("y")
    ^z::SwitchToByLetter("z")

    ; --- ★ 创建桌面 Ctrl+Shift+N，并直接跳转到新桌面 ★ ---
    ^+n:: {
        global gCurrentDesktop, gPreviousDesktop
        totalBefore := GetDesktopCount()
        CreateDesktop()

        ; 等待新桌面出现
        loop 50 {
            if (GetDesktopCount() > totalBefore)
                break
            Sleep(10)
        }

        newIdx := GetDesktopCount()
        if (newIdx > totalBefore) {
            gPreviousDesktop := gCurrentDesktop
            gCurrentDesktop := newIdx
            GoToDesktopNum(newIdx)
            UpdateUI(newIdx)
        }
    }

    ; --- 删除当前桌面 Ctrl+Delete（带确认提示） ---
    ^Delete:: {
        total := GetDesktopCount()
        if (total > 1) {
            currentName := GetDesktopName(gCurrentDesktop)
            if MsgBox("确定要删除当前虚拟桌面（" currentName "）吗？`n此操作不可撤销！", "删除确认", 4) = "Yes" {
                oldIdx := gCurrentDesktop
                fallbackIdx := (oldIdx == 1) ? 1 : (oldIdx - 1)
                RemoveDesktop(oldIdx, fallbackIdx)
                loop 50 {
                    if (GetCurrentDesktopNum() != oldIdx)
                        break
                    Sleep(10)
                }
                UpdateUI(GetCurrentDesktopNum())
            }
        } else {
            MsgBox("至少保留一个虚拟桌面，无法删除最后一个。", "提示", 64)
        }
    }

    ; --- 重命名 F2 ---
    F2:: {
        currentIdx := gCurrentDesktop
        currentName := GetDesktopName(currentIdx)
        IB := InputBox("请输入新的桌面名称：", "重命名当前桌面", "w300", currentName)
        if (IB.Result = "OK") {
            SetDesktopName(currentIdx, IB.Value)
            UpdateUI(currentIdx) 
        }
    }

#HotIf

; ======================================================================
; 7. 核心业务与 UI 渲染函数
; ======================================================================

SwitchTo(targetIndex) {
    global gCurrentDesktop, gPreviousDesktop
    if (targetIndex > GetDesktopCount() || targetIndex < 1)
        return
    if (gCurrentDesktop == targetIndex)
        return

    gPreviousDesktop := gCurrentDesktop

    if (GetKeyState("LButton", "P")) {
        try {
            activeHwnd := WinGetID("A")
            if (activeHwnd)
                MoveWindowToDesktopNum(activeHwnd, targetIndex)
        }
    }
    GoToDesktopNum(targetIndex)
    gCurrentDesktop := targetIndex
    UpdateUI(targetIndex)
}

SwitchNext() {
    nextIdx := gCurrentDesktop + 1
    if (nextIdx > GetDesktopCount())
        return 
    SwitchTo(nextIdx)
}

SwitchPrev() {
    prevIdx := gCurrentDesktop - 1
    if (prevIdx < 1)
        return 
    SwitchTo(prevIdx)
}

SwitchToPreviousDesktop() {
    global gCurrentDesktop, gPreviousDesktop
    if (gPreviousDesktop > 0 && gPreviousDesktop <= GetDesktopCount() && gPreviousDesktop != gCurrentDesktop) {
        temp := gCurrentDesktop
        GoToDesktopNum(gPreviousDesktop)
        gCurrentDesktop := gPreviousDesktop
        gPreviousDesktop := temp
        UpdateUI(gCurrentDesktop)
    }
}

SwitchToByLetter(letter) {
    global gCurrentDesktop
    total := GetDesktopCount()
    candidates := []

    loop total {
        idx := A_Index
        name := GetDesktopName(idx)
        if (name != "" && SubStr(name, 1, 1) ~= "[a-zA-Z]") {
            firstChar := StrLower(SubStr(name, 1, 1))
            if (firstChar == StrLower(letter)) {
                candidates.Push(idx)
            }
        }
    }

    if (candidates.Length == 0)
        return

    for i, idx in candidates {
        if (idx == gCurrentDesktop) {
            nextIndex := candidates[Mod(i, candidates.Length) + 1]
            SwitchTo(nextIndex)
            return
        }
    }

    SwitchTo(candidates[1])
}

TruncateString(str, maxLength := 16) {
    if (StrLen(str) > maxLength) {
        return SubStr(str, 1, maxLength) . "..."
    }
    return str
}

UpdateUI(targetIdx) {
    local currentIdx := 0
    if (targetIdx = 0) {
        currentIdx := gCurrentDesktop
    } else {
        currentIdx := targetIdx
    }

    rawName := GetDesktopName(currentIdx)
    global A_IconTip := rawName
    HUDText.Value := "❖  " . TruncateString(rawName, 16)
    
    SetTimer(StartFadeOut, 0)
    SetTimer(DoFadeOut, 0)
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
; 8. 系统底层虚拟桌面切换通知
; ======================================================================
DllCall(RegisterPostMessageHookProc, "Ptr", A_ScriptHwnd, "Int", 0x1400 + 30, "Int")
OnMessage(0x1400 + 30, OnChangeDesktop)

OnChangeDesktop(wParam, lParam, msg, hwnd) {
    Critical(1)
    newDesktopIdx := lParam + 1
    global gCurrentDesktop, gPreviousDesktop, A_IconTip
    if (newDesktopIdx != gCurrentDesktop) {
        gPreviousDesktop := gCurrentDesktop
        gCurrentDesktop := newDesktopIdx
    }
    A_IconTip := GetDesktopName(gCurrentDesktop)
}
