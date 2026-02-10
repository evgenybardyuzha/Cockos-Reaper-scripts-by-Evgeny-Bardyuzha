if not reaper.APIExists("JS_Window_SetPosition") then
    return
end

local seen = {}
local order = {}
local last_set = {}
local free_move = {}
local function get_rect(hwnd)
    local ok,l,t,r,b = reaper.JS_Window_GetRect(hwnd)
    if not ok then return nil end
    return {l=l,t=t,r=r,b=b,w=r-l,h=b-t}
end
local function point_in_rect(x,y,rc)
    return x>=rc.l and x<=rc.r and y>=rc.t and y<=rc.b
end
local function rects_overlap(a,b)
    return not (a.r<=b.l or a.l>=b.r or a.b<=b.t or a.t>=b.b)
end
local function list_plugin_windows()
    local res = {}
    local function add_hwnd(hwnd)
        if not hwnd then return end
        local rc = get_rect(hwnd)
        if rc then table.insert(res, { hwnd=hwnd, rc=rc }) end
    end
    local track_count = reaper.CountTracks(0)
    for i=0, track_count-1 do
        local tr = reaper.GetTrack(0, i)
        local fxn = reaper.TrackFX_GetCount(tr)
        for fx=0, fxn-1 do
            local hwnd = reaper.TrackFX_GetFloatingWindow(tr, fx)
            add_hwnd(hwnd)
        end
    end
    local mtr = reaper.GetMasterTrack(0)
    if mtr then
        local fxn = reaper.TrackFX_GetCount(mtr)
        for fx=0, fxn-1 do
            local hwnd = reaper.TrackFX_GetFloatingWindow(mtr, fx)
            add_hwnd(hwnd)
        end
    end
    return res
end
local function center_position(rc_main, rc_win)
    local cx = math.floor((rc_main.l + rc_main.r - rc_win.w)/2)
    local cy = math.floor((rc_main.t + rc_main.b - rc_win.h)/2)
    return cx, cy
end
local ring_state = {}
local function place_clockwise(anchor, rc_win, others)
    local key = tostring(anchor.hwnd)
    local st = ring_state[key] or {idx=1,level=1}
    local idx, level = st.idx, st.level
    local gap = 24 * level
    local aw = anchor.rc.w
    local ah = anchor.rc.h
    local acx = math.floor((anchor.rc.l + anchor.rc.r)/2)
    local acy = math.floor((anchor.rc.t + anchor.rc.b)/2)
    local function pos_for(i)
        if i == 1 then -- top
            return acx - math.floor(rc_win.w/2), anchor.rc.t - gap - rc_win.h
        elseif i == 2 then -- top-right
            return anchor.rc.r + gap, anchor.rc.t - gap - rc_win.h
        elseif i == 3 then -- right
            return anchor.rc.r + gap, acy - math.floor(rc_win.h/2)
        elseif i == 4 then -- bottom-right
            return anchor.rc.r + gap, anchor.rc.b + gap
        elseif i == 5 then -- bottom
            return acx - math.floor(rc_win.w/2), anchor.rc.b + gap
        elseif i == 6 then -- bottom-left
            return anchor.rc.l - gap - rc_win.w, anchor.rc.b + gap
        elseif i == 7 then -- left
            return anchor.rc.l - gap - rc_win.w, acy - math.floor(rc_win.h/2)
        elseif i == 8 then -- top-left
            return anchor.rc.l - gap - rc_win.w, anchor.rc.t - gap - rc_win.h
        end
        return acx - math.floor(rc_win.w/2), anchor.rc.t - gap - rc_win.h
    end
    local tries = 0
    while tries < 32 do
        local x,y = pos_for(idx)
        local test = {l=x,t=y,r=x+rc_win.w,b=y+rc_win.h,w=rc_win.w,h=rc_win.h}
        local overl=false
        for j=1,#others do
            if rects_overlap(test, others[j].rc) then overl=true break end
        end
        if not overl then
            st.idx = idx % 8 + 1
            if st.idx == 1 then st.level = level + 1 end
            ring_state[key] = st
            return x,y
        end
        idx = idx % 8 + 1
        if idx == 1 then level = level + 1; gap = 24 * level end
        tries = tries + 1
    end
    return acx - math.floor(rc_win.w/2), anchor.rc.b + gap
end
local function step()
    local main_rc = get_rect(reaper.GetMainHwnd())
    if not main_rc then reaper.defer(step) return end
    local wins = list_plugin_windows()
    local current = {}
    local bykey = {}
    for i=1,#wins do
        local key = tostring(wins[i].hwnd)
        current[key]=true
        bykey[key]=wins[i]
    end
    for i=#order,1,-1 do
        if not current[order[i]] then table.remove(order, i) end
    end
    for k,_ in pairs(last_set) do
        if not current[k] then
            last_set[k] = nil
            free_move[k] = nil
        end
    end
    for i=1,#wins do
        local key = tostring(wins[i].hwnd)
        local known=false
        for j=1,#order do if order[j]==key then known=true break end end
        if not known then table.insert(order, key) end
    end
    local cx_screen = math.floor((main_rc.l+main_rc.r)/2)
    local cy_screen = math.floor((main_rc.t+main_rc.b)/2)
    local function clamp(v, a, b) if v<a then return a elseif v>b then return b else return v end end
    local pos = {}
    if #order >= 1 then
        local w1 = bykey[order[1]].rc
        local x1 = cx_screen - math.floor(w1.w/2)
        local y1 = cy_screen - math.floor(w1.h/2)
        x1 = clamp(x1, main_rc.l, main_rc.r - w1.w)
        y1 = clamp(y1, main_rc.t, main_rc.b - w1.h)
        pos[order[1]] = {x=x1,y=y1,w=w1.w,h=w1.h}
    end
    if #order >= 2 then
        local w2 = bykey[order[2]].rc
        local x2 = clamp(cx_screen, main_rc.l, main_rc.r - w2.w)
        local y2 = cy_screen - math.floor(w2.h/2)
        y2 = clamp(y2, main_rc.t, main_rc.b - w2.h)
        pos[order[2]] = {x=x2,y=y2,w=w2.w,h=w2.h}
        local w1 = bykey[order[1]].rc
        local x1 = clamp(cx_screen - w1.w, main_rc.l, main_rc.r - w1.w)
        local y1 = pos[order[1]].y
        pos[order[1]] = {x=x1,y=y1,w=w1.w,h=w1.h}
    end
    if #order >= 3 then
        local w1 = bykey[order[1]].rc
        local w2 = bykey[order[2]].rc
        local y1 = clamp(cy_screen - w1.h, main_rc.t, main_rc.b - w1.h)
        local y2 = clamp(cy_screen - w2.h, main_rc.t, main_rc.b - w2.h)
        pos[order[1]].y = y1
        pos[order[2]].y = y2
        local w3 = bykey[order[3]].rc
        local x3 = pos[order[2]].x
        local y3 = clamp(cy_screen + 10, main_rc.t, main_rc.b - w3.h)
        pos[order[3]] = {x=x3,y=y3,w=w3.w,h=w3.h}
    end
    if #order >= 4 then
        local w4 = bykey[order[4]].rc
        local p1 = pos[order[1]]
        local x4 = clamp(p1.x + p1.w - w4.w, main_rc.l, main_rc.r - w4.w)
        local y4 = clamp(pos[order[3]] and pos[order[3]].y or (cy_screen + 10), main_rc.t, main_rc.b - w4.h)
        pos[order[4]] = {x=x4,y=y4,w=w4.w,h=w4.h}
    end
    if #order > 4 then
        local max_i = (#order >= 8) and 8 or #order
        if #order >= 5 then
            local w5 = bykey[order[5]].rc
            local p1 = pos[order[1]]
            if p1 then
                local x5 = clamp(p1.x + p1.w - w5.w, main_rc.l, main_rc.r - w5.w)
                local y5 = clamp(p1.y + p1.h - w5.h, main_rc.t, main_rc.b - w5.h)
                pos[order[5]] = {x=x5,y=y5,w=w5.w,h=w5.h}
            end
        end
        if #order >= 6 then
            local w6 = bykey[order[6]].rc
            local p2 = pos[order[2]]
            if p2 then
                local x6 = clamp(p2.x, main_rc.l, main_rc.r - w6.w)
                local y6 = clamp(p2.y + p2.h - w6.h, main_rc.t, main_rc.b - w6.h)
                pos[order[6]] = {x=x6,y=y6,w=w6.w,h=w6.h}
            end
        end
        if #order >= 7 then
            local w7 = bykey[order[7]].rc
            local p3 = pos[order[3]]
            if p3 then
                local x7 = clamp(p3.x, main_rc.l, main_rc.r - w7.w)
                local y7 = clamp(p3.y, main_rc.t, main_rc.b - w7.h)
                pos[order[7]] = {x=x7,y=y7,w=w7.w,h=w7.h}
            end
        end
        if #order >= 8 then
            local w8 = bykey[order[8]].rc
            local p4 = pos[order[4]]
            if p4 then
                local x8 = clamp(p4.x + p4.w - w8.w, main_rc.l, main_rc.r - w8.w)
                local y8 = clamp(p4.y, main_rc.t, main_rc.b - w8.h)
                pos[order[8]] = {x=x8,y=y8,w=w8.w,h=w8.h}
            end
        end
        for i=5,max_i do
            local key = order[i]
            local rc = bykey[key].rc
            local target_idx = i - 4
            local tp = pos[order[target_idx]]
            if tp then
                if not pos[key] then
                    local x = tp.x
                    local y = clamp(tp.y + tp.h + 10, main_rc.t, main_rc.b - rc.h)
                    pos[key] = {x=x,y=y,w=rc.w,h=rc.h}
                end
            end
        end
        if #order > 8 then
            local last_right = 3
            local last_left = 4
            for i=9,#order do
                local key = order[i]
                local rc = bykey[key].rc
                if i % 2 == 1 then
                    local pk = order[last_right]
                    local pp = pos[pk]
                    local x = pp.x
                    local y = clamp(pp.y + pp.h, main_rc.t, main_rc.b - rc.h)
                    pos[key] = {x=x,y=y,w=rc.w,h=rc.h}
                    last_right = i
                else
                    local pk = order[last_left]
                    local pp = pos[pk]
                    local x = pp.x
                    local y = clamp(pp.y + pp.h, main_rc.t, main_rc.b - rc.h)
                    pos[key] = {x=x,y=y,w=rc.w,h=rc.h}
                    last_left = i
                end
            end
        end
    end
    for i=1,#order do
        local key = order[i]
        local p = pos[key]
        if p then
            local hwnd = bykey[key].hwnd
            local rc = bykey[key].rc
            if not free_move[key] then
                if last_set[key] then
                    local dx = math.abs(rc.l - last_set[key].x)
                    local dy = math.abs(rc.t - last_set[key].y)
                    if dx > 2 or dy > 2 then
                        free_move[key] = true
                    else
                        reaper.JS_Window_SetPosition(hwnd, p.x, p.y, p.w, p.h, "", "")
                        last_set[key] = {x=p.x,y=p.y}
                    end
                else
                    reaper.JS_Window_SetPosition(hwnd, p.x, p.y, p.w, p.h, "", "")
                    last_set[key] = {x=p.x,y=p.y}
                end
            end
            seen[key]=true
        end
    end
    reaper.defer(step)
end
step()

