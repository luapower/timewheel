--[[
  mgit bundle -M timewheel -z -o timewheel.exe
   -a "cairo pixman png z freetype"
   -m "winapi winapi/* cairo* cplayer cplayer/* timewheel glue box2d path2d_* pp* color codedit_str utf8"
]]
local player = require'cplayer'
local point = require'path2d_point'
local arc = require'path2d_arc'
local box = require'box2d'
local pp = require'pp'
local cairo = require'cairo'
local color = require'color'

--pan & zoom state
local mt_scale = 2
local mt = cairo.matrix():scale(mt_scale)
local mt1_scale = 1
local mt1 = cairo.matrix()
local zoom, pan, rotate
local mx, my

local start_time
local max_deg = 360
local years = 1

player.show_magnifier = false

function player:on_render(cr)

	--UI ----------------------------------------------------------------------

	local d = os.date'*t'
	start_time = start_time or os.time{year = d.year, month = d.month, day = 1, hour = 0, sec = 0}
	local min_st = os.time{year = d.year, month = 1, day = 1, hour = 0, sec = 0}
	local max_st = os.time{year = d.year, month = d.month, day = d.day, hour = 0, sec = 0}

	start_time = self:slider{
			id = 'start_time',
			x = 10, y = 70, w = 160, h = 24,
			i0 = min_st, i1 = max_st, step = 1/1000,
			i = start_time,
			text = 'start_time',
		}

	max_deg = self:slider{
			id = 'max_deg',
			x = 10, y = 100, w = 160, h = 24,
			i0 = 0, i1 = 360, step = 1/1000,
			i = max_deg,
			text = 'max_deg',
		}

	years = self:slider{
			id = 'years',
			x = 10, y = 130, w = 160, h = 24,
			i0 = 1/4, i1 = 2, step = 1/1000,
			i = years or 1,
			text = 'years',
		}

	if self:button{
			id = 'reset',
			x = 10, y = 10, w = 160, h = 24,
			text = 'reset',
			theme = self.themes.red,
		} then
			mt:reset()
		end

	self:text(10, 220, [[
HELP:

Scroll Wheel                    : Zoom
Left-Click Drag                 : Rotate
  + Hold Space                  : Move
Hold Shift + Mouse Move Up/Down : Fine Zoom
Hold Ctrl  + Mouse Move         : Pan
]], 'Courier New, 14, bold')

	--math utils --------------------------------------------------------------

	local function mod(x, max)
		return (x-1) % max + 1
	end

	local function clamp(x, min, max)
		return math.min(math.max(x, min), max)
	end

	local function fit(t0, d, min, max)
		local t1 = t0 + d
		t0 = clamp(t0, min, max)
		t1 = clamp(t1, min, max)
		d = t1 - t0
		return t0, d
	end

	--calendar utils ----------------------------------------------------------

	local function make_iterator(get_interval)
		return function(start_time, total_interval)
			local end_time = start_time + total_interval
			local t, d, i = start_time, 0, 0
			local function iter()
				t, d, i = get_interval(t + d)
				if t >= end_time then
					return
				end
				local is_last = t + d >= end_time
				local ft, fd = fit(t, d, start_time, end_time)
				if fd == 0 then --skip all-in-the-past segments
					return iter()
				end
				return ft, fd, i, is_last, t, d
			end
			return iter
		end
	end

	local year_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local t0 = os.time{year = d.year, month = 1, day = 1, hour = 0, sec = 0}
		local t1 = os.time{year = d.year + 1, month = 1, day = 1, hour = 0, sec = 0}
		return t0, t1 - t0, d.year
	end)

	local month_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local t0 = os.time{year = d.year, month = d.month, day = 1, hour = 0, sec = 0}
		local t1 = os.time{year = d.year, month = d.month + 1, day = 1, hour = 0, sec = 0}
		return t0, t1 - t0, d.month
	end)

	local quarter_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local q = math.floor((d.month - 1) / 3) + 1
		local t0 = os.time{year = d.year, month = (q - 1) * 3 + 1, day = 1, hour = 0, sec = 0}
		local t1 = os.time{year = d.year, month = (q - 1) * 3 + 4, day = 1, hour = 0, sec = 0}
		return t0, t1 - t0, q
	end)

	--month of season-start for each month
	local sm = {0,0,3,3,3,6,6,6,9,9,9,12}
	--days of spring equinox, summer solstice, autumn equinox, winter solstice
	local sd = {20, 21, 22, 21}
	local season_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local m1 = sm[d.month]
		local m2, s1, s2, d1, d2
		::again::
		m2 = m1 + 3
		s1 = math.floor(m1 / 3) % 4 + 1
		s2 = math.floor(m2 / 3) % 4 + 1
		d1 = sd[s1]
		d2 = sd[s2]
		if m1 == d.month and d1 > d.day then
			m1 = m1 - 3
			goto again
		end
		local t0 = os.time{year = d.year, month = m1, day = d1, hour = 0, sec = 0}
		local t1 = os.time{year = d.year, month = m2, day = d2, hour = 0, sec = 0}
		return t0, t1 - t0, s1
	end)

	local week_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local wd = d.day - mod(d.wday - 1, 7) + 1
		local t0 = os.time{year = d.year, month = d.month, day = wd, hour = 0, sec = 0}
		local t1 = os.time{year = d.year, month = d.month, day = wd + 7, hour = 0, sec = 0}
		return t0, t1 - t0, wd
	end)

	local day_times = make_iterator(function(time)
		local d = os.date('*t', time)
		local t0 = os.time{year = d.year, month = d.month, day = d.day, hour = 0, sec = 0}
		local t1 = os.time{year = d.year, month = d.month, day = d.day + 1, hour = 0, sec = 0}
		return t0, t1 - t0, mod(d.wday - 1, 7)
	end)

	--state -------------------------------------------------------------------

	local r = 280

	local w = self.panel.client_w
	local h = self.panel.client_h
	local cx = (w - r - 100)
	local cy = h
	self.init_mt = self.init_mt or mt:copy():invert()
	cx, cy = self.init_mt:point(cx, cy)

	--analog time
	local total_interval = years * 365 * 24 * 3600
	local end_time = start_time + total_interval

	local function deg(time)
		return (time - start_time) / total_interval * max_deg
	end

	local function time(deg)
		return start_time + deg / max_deg * total_interval
	end

	local now_time = os.time()
	if now_time >= end_time then
		now_time = nil
	end

	--zoom & pan --------------------------------------------------------------

	cr:transform(mt)

	local function mouse()
		return cr:device_to_user(self.mousex, self.mousey)
	end

	local function mt1_end()
		mt:transform(mt1)
		cr:transform(mt1)
		mt1:reset()
		mt_scale = mt_scale * mt1_scale
		mt1_scale = 1
	end

	local function zoom_start(mx1, my1)
		zoom = true
		mx, my = mx1, my1
	end

	local function zoom_do(d, mx1, my1)
		local scale = clamp(1 + (my - my1) / 20 * d, 0.2, 100)
		local tx = mx * (scale - 1)
		local ty = my * (scale - 1)
		mt1:reset():translate(-tx, -ty):scale(scale)
		mt1_scale = scale
	end

	local function zoom_end()
		mt1_end()
		zoom = false
	end

	local function pan_start(how)
		pan = how
		mx, my = mouse()
	end

	local function pan_do()
		local mx1, my1 = mouse()
		local panx, pany
		if pan == 'normal' then
			panx = (mx1 - mx)
			pany = (my1 - my)
		else
			panx = (mx - mx1) * mt_scale
			pany = (my - my1) * mt_scale
		end
		mt1:reset():translate(panx, pany)
	end

	local function pan_end()
		mt1_end()
		pan = false
	end

	local function rotate_start()
		rotate = true
		mx, my = mouse()
	end

	local function rotate_do()
		local a0 = point.point_angle(mx, my, cx, cy)
		local mx1, my1 = mouse()
		local a1 = point.point_angle(mx1, my1, cx, cy)
		local rotation = math.rad(a1 - a0)
		mt1:reset():rotate_around(cx, cy, rotation)
	end

	local function rotate_end()
		mt1_end()
		rotate = false
	end

	if not self.active then

		if not zoom and not pan and not rotate then
			if self.wheel_delta ~= 0 then
				zoom_start(mouse())
				zoom_do(1, mx, my - self.wheel_delta * 10)
				zoom_end()
			elseif self.key == 'shift' then
				zoom_start(mouse())
			elseif self.key == 'ctrl' then
				pan = 'inverted'
			elseif self.lbutton then
				if self:keypressed'space' then
					pan = 'normal'
				else
					rotate = true
				end
			end
			if pan then
				pan_start(pan)
			elseif rotate then
				rotate_start()
			end
		elseif rotate then
			if not self.lbutton or self:keypressed'space' then
				rotate_end()
			else
				rotate_do()
			end
		elseif pan == 'normal' then
			if not self.lbutton or not self:keypressed'space' then
				pan_end()
			else
				pan_do()
			end
		elseif pan == 'inverted' then
			if not self:keypressed'ctrl' then
				pan_end()
			else
				pan_do()
			end
		elseif zoom then
			if not self:keypressed'shift' then
				zoom_end()
			else
				zoom_do(mt_scale, mouse())
			end
		end

	end

	cr:transform(mt1)

	if now_time then
		cr:rotate_around(cx, cy, math.rad(-deg(now_time)-90))
	end

	--hit-testing -------------------------------------------------------------

	local mx, my = mouse()
	local hit_time = time(point.point_angle(mx, my, cx, cy))

	local function hit_test(time, interval)
		return hit_time >= time and hit_time <= time + interval
	end

	--clip-testing ------------------------------------------------------------

	local function in_clip(time, w, r1, h)
		local a1 = deg(time)
		local w = deg(time + w) - a1
		local r1 = r + r1
		local r2 = r1 + h
		local bx1, by1, bw1, bh1 = arc.bounding_box(cx, cy, r1, r1, a1, w)
		local bx2, by2, bw2, bh2 = arc.bounding_box(cx, cy, r2, r2, a1, w)
		local bx, by, bw, bh = box.bounding_box(
			bx1, by1, bw1, bh1,
			bx2, by2, bw2, bh2)
		--[[
		self:setcolor'#fff'
		cr:rectangle(bx, by, bw, bh)
		cr:stroke()
		]]
		return box.overlapping(bx, by, bw, bh, box.rect(cr:clip_extents()))
	end

	--drawing utils -----------------------------------------------------------

	local function in_view(t, w, r1, h)
		--
	end

	local function tick(time, r1, h, w, color)
		local a = deg(time)
		local r2 = r1 + h
		local x1, y1 = point.point_around(cx, cy, r + r1, a)
		local x2, y2 = point.point_around(cx, cy, r + r2, a)
		if w then
			cr:line_width(w)
		end
		if color then
			self:setcolor(color)
		end
		cr:move_to(x1, y1)
		cr:line_to(x2, y2)
		cr:stroke()
	end

	local function arc(time, w, r1, h, color)
		local a = deg(time)
		local w = deg(time + w) - a
		local r2 = h and r1 + h or r1
		local rc = r1 + h / 2
		local x1, y1 = point.point_around(cx, cy, r + rc, a)
		if h then
			cr:line_width(h)
		end
		if color then
			self:setcolor(color)
		end
		cr:move_to(x1, y1)
		cr:arc(cx, cy, r + rc, math.rad(a), math.rad(a + w))
		cr:stroke()
	end

	local function text(time, r1, s, font, color)
		local a = deg(time)
		local x, y = point.point_around(0, 0, r + r1, a)
		cr:translate(x, y)
		local a = math.rad(a + 90)
		cr:rotate_around(cx, cy, a)
		self:text(cx, cy, s, font, color, 'center')
		cr:rotate_around(cx, cy, -a)
		cr:translate(-x, -y)
	end

	--drawing -----------------------------------------------------------------

	local function center(t, d)
		t, d = fit(t, d, start_time, end_time)
		return t + d / 2
	end

	--months
	local month_names = {
		'jan', 'feb', 'mar', 'apr', 'may', 'jun',
		'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
	}
	for t, d, i in month_times(start_time, total_interval) do
		if t >= start_time then
			tick(t, -10, 20, 2, '#888')
			text(center(t, d), -10, month_names[mod(i, 12)], 'Arial,16', '#fff')
		end
	end

	--years
	local c = color'#888'
	for t, d, i, is_last in year_times(start_time, total_interval) do
		local cs = c:tostring()
		tick(t, -10, 40, 2, cs)
		if is_last then
			tick(t + d, -10, 40, 2, cs)
		end
		arc(t, d, 10, 6, cs)
		text(center(t, d), -220, i, 'Arial,32,bold', '#111')
		c = c:lighten_by(1/2)
	end

	--quarters
	local c = color'#888'
	for t, d, i in quarter_times(start_time, total_interval) do
		local cs = c:tostring()
		arc(t, d, -120, 6, cs)
		tick(t, -100, -30, 1, cs)
		text(center(t, d), -140, 'Q '..mod(i, 4), 'Arial,16', cs)
		c = c:lighten_by(1/2)
	end

	--seasons
	local season_colors = {
		color'#ffffff', --winter
		color'#008800', --spring
		color'#ffaa00', --summer
		color'#885511', --autumn
	}
	local season_names = {'winter', 'spring', 'summer', 'autumn'}
	for t, d, i in season_times(start_time, total_interval) do
		i = mod(i, 4)
		local c = season_colors[i]
		arc(t, d, 20, 6, c:tostring())
		text(center(t, d), 30, season_names[i], 'Arial,12', '#fff')
	end

	local sf = (mt_scale >= 8 and mt_scale or 1)

	--weeks
	for ft, fd, i, is_last, t, d in week_times(start_time, total_interval) do
		if t >= start_time then
			tick(t, -20, 6, 0.5 / sf, '#fff')
		end
		--text(center(t, d), -30, week, 'Arial,11', '#fff')
	end

	--days
	local wd_names = {'L', 'm', 'M', 'J', 'V', 'S', 'D'}
	for t, d, i, is_last in day_times(start_time, total_interval) do
		tick(t, -20, 3, 0.2 / sf, '#fff')
		if mt_scale >= 8 and in_clip(t, d, -20, 2) then
			text(center(t, d), -20, wd_names[i], 'Arial,2', '#fff')
			if mt_scale >= 100 then
				for i=0,23 do
					local d = 3600
					local t = t + i*d
					tick(t, -18, 0.2, 0.5 / sf, '#fff')
					local s = mod(i+1, 12)..(i >= 12 and 'pm' or 'am')
					text(t + d/2, -18, s, 'Arial,0.05', '#fff')
				end
			end
		end
	end

	if now_time then
		tick(now_time, -r, r+10, 1 / mt_scale, '#888')
	end
	tick(hit_time, -30, 10, 1 / mt_scale, '#f00')

	--linear timeline ---------------------------------------------------------


end

player:play()
