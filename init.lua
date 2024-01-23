local load_time_start = minetest.get_us_time()

-- Override the API to ensure the item isn't picked up instantly
-- (based on workaround provided at
-- <https://github.com/minetest/minetest/issues/13954>).
local minetest_item_drop = minetest.item_drop
function minetest.item_drop(itemstack, dropper, pos)  -- supposed to return leftover item
	if dropper and dropper.get_player_name then
		local meta = itemstack:get_meta()
		meta:set_string("dropped_by", dropper:get_player_name())
		-- ^ every drop should call core.item_drop (which sets ent.dropped_by)
		--   but MultiCraft doesn't (ent.dropped_by isn't set), so use metadata instead.
	end
	return minetest_item_drop(itemstack, dropper, pos)  -- default behavior
end


function deserialize_extended(itemstring)
	if not itemstring then
		return nil
	end
	-- such as 'mobs:meat_raw 9 0 "\u0001dropped_by\u0002Player\u0003"'
	local start = itemstring:find("\\u0001")
	local sep = itemstring:find("\\u0002")
	local ender = itemstring:find("\\u0003")
	if start and sep and ender then
		return {[itemstring:sub(start+6, sep-1)] = itemstring:sub(sep+6, ender-1)}
	end
	return nil
end


function ent_dropped_by(ent)
	-- Check for builtin or extended dropped_by value:
	-- * ent.dropped_by: is set by minetest.item_drop, but is nil in certain
	--   cases (potentially a timing issue or related to overrides in
	--   certain mods or versions of Minetest).
	-- * extended itemstring: It only contains a "dropped_by" value if using
	--   item_drop mod (since minetest.item_drop is overridden to use set_meta).
	local dropped_by = nil
	if not ent then
		return nil
	end
	dropped_by = ent.dropped_by
	if not dropped_by and ent and ent.itemstring then
		local data = deserialize_extended(ent.itemstring)
		if data then
			dropped_by = data.dropped_by
		end
	end
	return dropped_by
end


function obj_dropped_by(object)
	-- Check for builtin or extended dropped_by value.
	-- See ent_dropped_by for further information.
	if object:is_player() then
		return
	end
	local ent = object:get_luaentity()
	return ent_dropped_by(ent)
end


-- Functions which can be overridden by mods
item_drop = {
	-- This function is executed before picking up an item or making it fly to
	-- the player. If it does not return true, the item is ignored.
	-- It is also executed before collecting the item after it flew to
	-- the player and did not reach him/her for magnet_time seconds.
	can_pickup = function(entity, player)
		if entity.item_drop_picked then
			-- Ignore items where picking has already failed
			return false
		end
		return true
	end,

	-- before_collect and after_collect are executed before and after an item
	-- is collected by a player
	before_collect = function(entity, pos, player)
	end,
	after_collect = function(entity, pos, player)
		entity.item_drop_picked = true
	end,
}

local function legacy_setting_getbool(name_new, name_old, default)
	local v = minetest.settings:get_bool(name_new)
	if v == nil then
		v = minetest.settings:get_bool(name_new)
	end
	if default then
		return v ~= false
	end
	return v
end


local function legacy_setting_getnumber(name_new, name_old, default)
	return tonumber(minetest.settings:get(name_new))
		or tonumber(minetest.settings:get(name_old))
		or default
end


if legacy_setting_getbool("item_drop.enable_item_pickup",
		"enable_item_pickup", true) then
	local pickup_gain = legacy_setting_getnumber("item_drop.pickup_sound_gain",
		"item_pickup_gain", 0.2)
	local pickup_particle =
		minetest.settings:get_bool("item_drop.pickup_particle", true)
	local pickup_radius = legacy_setting_getnumber("item_drop.pickup_radius",
		"item_pickup_radius", 0.4)  -- 1.425 is better if magnet_radius < this.
	local magnet_radius = tonumber(
		minetest.settings:get("item_drop.magnet_radius")) or 1.4
	local magnet_time = tonumber(
		minetest.settings:get("item_drop.magnet_time")) or 1.0
	local pickup_age = tonumber(
		minetest.settings:get("item_drop.pickup_age")) or 2.5
	local key_triggered = legacy_setting_getbool("item_drop.enable_pickup_key",
		"enable_item_pickup_key", true)
	local key_invert = minetest.settings:get_bool(
		"item_drop.pickup_keyinvert") ~= false
	local keytype
	if key_triggered then
		keytype = minetest.settings:get("item_drop.pickup_keytype") or
		minetest.settings:get("item_pickup_keytype") or "Use"
		-- disable pickup age if picking is explicitly enabled by the player
		if not key_invert then
			pickup_age = math.min(pickup_age, 0)
		end
	end
	local mouse_pickup = minetest.settings:get_bool(
		"item_drop.mouse_pickup") ~= false
	if not mouse_pickup then
		minetest.registered_entities["__builtin:item"].pointable = false
	end

	local magnet_mode = magnet_radius > pickup_radius
	local zero_velocity_mode = pickup_age == -1
	if magnet_mode
	and zero_velocity_mode then
		error"zero velocity mode can't be used together with magnet mode"
	end

	-- tells whether an inventorycube should be shown as pickup_particle or not
	-- for known drawtypes
	local inventorycube_drawtypes = {
		normal = true,
		allfaces = true,
		allfaces_optional = true,
		glasslike = true,
		glasslike_framed = true,
		glasslike_framed_optional = true,
		liquid = true,
		flowingliquid = true,
	}

	-- Get an image string from a tile definition
	local function tile_to_image(tile, fallback_image)
		if not tile then
			return fallback_image
		end
		local tile_type = type(tile)
		if tile_type == "string" then
			return tile
		end
		assert(tile_type == "table", "Tile definition is not a string or table")
		local image = tile.name or tile.image
		assert(image, "Tile definition has no image file specified")
		if tile.color then
			local colorstr = minetest.colorspec_to_colorstring(tile.color)
			if colorstr then
				return image .. "^[multiply:" .. colorstr
			end
		end
		return image
	end

	-- adds the item to the inventory and removes the object
	local function collect_item(ent, pos, player)
		item_drop.before_collect(ent, pos, player)
		minetest.sound_play("item_drop_pickup", {
			pos = pos,
			gain = pickup_gain,
		}, true)
		if pickup_particle then
			local item = minetest.registered_nodes[
				ent.itemstring:gsub("(.*)%s.*$", "%1")]
			local image
			if item and item.tiles and item.tiles[1] then
				if inventorycube_drawtypes[item.drawtype] then
					local tiles = item.tiles
					-- color in the tile definition is handled by tile_to_image.
					-- color in the node definition is not yet supported here.
					local top = tile_to_image(tiles[1])
					local left = tile_to_image(tiles[3], top)
					local right = tile_to_image(tiles[5], left)
					image = minetest.inventorycube(top, left, right)
				else
					image = item.inventory_image or item.tiles[1]
				end
				minetest.add_particle({
					pos = {x = pos.x, y = pos.y + 1.5, z = pos.z},
					velocity = {x = 0, y = 1, z = 0},
					acceleration = {x = 0, y = -4, z = 0},
					expirationtime = 0.2,
					size = 3,--math.random() + 0.5,
					vertical = false,
					texture = image,
				})
			end
		end
		ent:on_punch(player)
		item_drop.after_collect(ent, pos, player)
	end

	-- opt_get_ent gets the object's luaentity if it can be collected
	local opt_get_ent
	if zero_velocity_mode then
		function opt_get_ent(object)
			if object:is_player()
			or not vector.equals(object:get_velocity(), {x=0, y=0, z=0}) then
				minetest.chat_send_player("singleplayer", "already moving")
				minetest.chat_send_player("Player", "already moving")
				return
			end
			local ent = object:get_luaentity()
			if not ent
			or ent.name ~= "__builtin:item"
			or ent.itemstring == "" then
				if ent then
					minetest.chat_send_player("singleplayer", "ent.itemstring="..ent.itemstring)
					minetest.chat_send_player("Player", "ent.itemstring="..ent.itemstring)
				end
				return
			end
			return ent
		end
	else
		function opt_get_ent(object)
			if object:is_player() then
				return
			end
			local ent = object:get_luaentity()
			local dropped_by = ent_dropped_by(ent)
			if not ent
			or ent.name ~= "__builtin:item"
			or (dropped_by and ent.age < pickup_age)
			or ent.itemstring == "" then
				return
			end
			return ent
		end
	end

	local afterflight
	if magnet_mode then
		-- take item or reset velocity after flying a second
		function afterflight(object, inv, player)
			-- TODO: test what happens if player left the game
			local ent = opt_get_ent(object)
			if not ent then
				return
			end
			-- Case below is commented so player does *not* collect it unless
			--   it is in collect range!
			--   -Poikilos 2024-01-07
			-- local item = ItemStack(ent.itemstring)
			-- if inv
			-- and inv:room_for_item("main", item)
			-- and item_drop.can_pickup(ent, player) then
			-- 	collect_item(ent, object:get_pos(), player)
			-- else
			-- the acceleration will be reset by the object's on_step
			ent.is_magnet_item = false
			object:set_velocity({x=0,y=0,z=0})
			object:set_physics_override({["gravity"] = 1.0})  -- let item fall
			-- -Poikilos 2024-01-07
			-- end
		end

		-- disable velocity and acceleration changes of items flying to players
		minetest.after(0, function()
			local ObjectRef
			-- local blocked_methods = {"set_acceleration", "set_velocity",
			-- 	"setacceleration", "setvelocity"}
			local blocked_methods = {}  -- empty (blocking no functions) is hard-coded way to allow both normal&custom physics of flying item
			-- -Poikilos 2024-01-07

			local itemdef = minetest.registered_entities["__builtin:item"]
			local old_on_step = itemdef.on_step
			local function do_nothing() end
			function itemdef.on_step(self, ...)
				if not self.is_magnet_item then
					return old_on_step(self, ...)
				end
				ObjectRef = ObjectRef or getmetatable(self.object)
				local old_funcs = {}
				for i = 1, #blocked_methods do
					local method = blocked_methods[i]
					old_funcs[method] = ObjectRef[method]
					ObjectRef[method] = do_nothing
				end
				old_on_step(self, ...)
				for i = 1, #blocked_methods do
					local method = blocked_methods[i]
					ObjectRef[method] = old_funcs[method]
				end
			end
		end)
	end

	-- set keytype to the key name if possible
	if keytype == "Use" then
		keytype = "aux1"
	elseif keytype == "Sneak" then
		keytype = "sneak"
	elseif keytype == "LeftAndRight" then -- LeftAndRight combination
		keytype = 0
	elseif keytype == "SneakAndRMB" then -- SneakAndRMB combination
		keytype = 1
	end


	-- tests if the player has the keys pressed to enable item picking
	local function has_keys_pressed(player)
		if not key_triggered then
			return true
		end

		local control = player:get_player_control()
		local keys_pressed
		if keytype == 0 then -- LeftAndRight combination
			keys_pressed = control.left and control.right
		elseif keytype == 1 then -- SneakAndRMB combination
			keys_pressed = control.sneak and control.RMB
		else
			keys_pressed = control[keytype]
		end

		return keys_pressed ~= key_invert
	end

	local function is_inside_map(pos)
		local bound = 31000
		return -bound < pos.x and pos.x < bound
			and -bound < pos.y and pos.y < bound
			and -bound < pos.z and pos.z < bound
	end

	-- called for each player to possibly collect an item, returns true if so
	local function pickupfunc(player)
		if not has_keys_pressed(player)
		or not minetest.get_player_privs(player:get_player_name()).interact
		or player:get_hp() <= 0 then
			return
		end

		local pos = player:get_pos()
		if not is_inside_map(pos) then
			-- get_objects_inside_radius crashes for too far positions
			return
		end
		pos.y = pos.y+0.5
		local inv = player:get_inventory()

		local objectlist = minetest.get_objects_inside_radius(pos,
			magnet_mode and magnet_radius or pickup_radius)
		for i = 1,#objectlist do
			local object = objectlist[i]
			local ent = opt_get_ent(object)
			local dropped = false
			if player
			and player.get_player_name
			then
				local dropped_by = nil
				if ent then
					-- for some reason ent.dropped_by and object.dropped_by are both nil
					dropped_by = ent.dropped_by
					if dropped_by then
						minetest.chat_send_player(player:get_player_name(), type(dropped_by).." ent.dropped_by="..dropped_by)
					else
						minetest.chat_send_player(player:get_player_name(), type(dropped_by).." ent.dropped_by=nil")
					end
					dropped_by = ent_dropped_by(ent)
					if dropped_by == player:get_player_name() then
						dropped = true
					end
				else
					local non_item_ent = object:get_luaentity()
					if non_item_ent then
						if non_item_ent.name then
							if not non_item_ent.age or non_item_ent.age > pickup_age then
								minetest.chat_send_player(player:get_player_name(), "moving, new, or non-item ent.name="..non_item_ent.name)
								minetest.chat_send_player(player:get_player_name(), "object:get_velocity()="..minetest.serialize(object:get_velocity()))
							end
							-- else it is recently dropped, ignore until gets evaluated
						end
					end
				end
				if dropped_by then
					minetest.chat_send_player(player:get_player_name(), "Dropped by "..dropped_by)
				elseif ent then
					minetest.chat_send_player(player:get_player_name(), "(dropped "..ent:get_staticdata()..")")
				end
			end

			if ent
			and item_drop.can_pickup(ent, player)
			and not dropped then
				local item = ItemStack(ent.itemstring)
				if inv:room_for_item("main", item) then
					minetest.chat_send_player(player:get_player_name(), "Not dropped.")
					local flying_item
					local pos2
					if magnet_mode then
						pos2 = object:get_pos()
						flying_item = vector.distance(pos, pos2) > pickup_radius
					end
					if not flying_item then
						-- The item is near enough to pick it
						collect_item(ent, pos, player)
						-- Collect one item at a time to avoid the loud pop
						return true
					end
					-- The item is not too far a way but near enough to be
					-- magnetised, make it fly to the player
					local vel = vector.multiply(vector.subtract(pos, pos2), 2)
					-- ^ changed to 2 since 3 is too fast (cancels out distance-based difficulty curve)
					vel.y = vel.y + 0.6
					-- ^ Commented since a slight challenge is more fun
					-- (having to get close to item adds to gameplay)
					-- -Poikilos 2024-01-07
					object:set_velocity(vel)
					if not ent.is_magnet_item then
						ent.object:set_acceleration({x=0, y=0, z=0})
						ent.is_magnet_item = true
						minetest.after(magnet_time, afterflight,
							object, inv, player)
					end
				else
					minetest.chat_send_player(player:get_player_name(), "Not dropped (no room).")
				end
			end
		end
	end

	local function pickup_step()
		local got_item
		local players = minetest.get_connected_players()
		for i = 1,#players do
			got_item = got_item or pickupfunc(players[i])
		end
		-- lower step if takeable item(s) were found
		local time
		if got_item then
			time = 0.02
		else
			time = 0.2
		end
		minetest.after(time, pickup_step)
	end
	minetest.after(3.0, pickup_step)
end

if legacy_setting_getbool("item_drop.enable_item_drop", "enable_item_drop", true)
and not minetest.settings:get_bool("creative_mode") then
	-- Workaround to test if an item metadata (ItemStackMetaRef) is empty
	local function itemmeta_is_empty(meta)
		local t = meta:to_table()
		for k, v in pairs(t) do
			if k ~= "fields" then
				return false
			end
			assert(type(v) == "table")
			if next(v) ~= nil then
				return false
			end
		end
		return true
	end

	-- Tests if the item has special information such as metadata
	local function can_split_item(item)
		return item:get_wear() == 0 and itemmeta_is_empty(item:get_meta())
	end

	local function spawn_items(pos, items_to_spawn)
		for i = 1,#items_to_spawn do
			local obj = minetest.add_item(pos, items_to_spawn[i])
			if not obj then
				error("Couldn't spawn item " .. name .. ", drops: "
					.. dump(drops))
			end

			local vel = obj:get_velocity()
			local x = math.random(-5, 4)
			if x >= 0 then
				x = x+1
			end
			vel.x = 1 / x
			local z = math.random(-5, 4)
			if z >= 0 then
				z = z+1
			end
			vel.z = 1 / z
			minetest.chat_send_player("singleplayer", "set_velocity "..minetest.serialize(vel))
			minetest.chat_send_player("Player", "set_velocity "..minetest.serialize(vel))
			obj:set_velocity(vel)
		end
	end

	local old_handle_node_drops = minetest.handle_node_drops
	function minetest.handle_node_drops(pos, drops, player)
		if not player or player.is_fake_player then
			-- Node Breaker or similar machines should receive items in the
			-- inventory
			return old_handle_node_drops(pos, drops, player)
		end
		for i = 1,#drops do
			local item = drops[i]
			if type(item) == "string" then
				-- The string is not necessarily only the item name,
				-- so always convert it to ItemStack
				item = ItemStack(item)
			end
			local count = item:get_count()
			local name = item:get_name()

			-- Sometimes nothing should be dropped
			if name == ""
			or not minetest.registered_items[name] then
				count = 0
			end

			if count > 0 then
				-- Split items if possible
				local items_to_spawn = {item}
				if can_split_item(item) then
					for i = 1,count do
						items_to_spawn[i] = name
					end
				end

				spawn_items(pos, items_to_spawn)
			end
		end
	end
end


local time = (minetest.get_us_time() - load_time_start) / 1000000
local msg = "[item_drop] loaded after ca. " .. time .. " seconds."
if time > 0.01 then
	print(msg)
else
	minetest.log("info", msg)
end
