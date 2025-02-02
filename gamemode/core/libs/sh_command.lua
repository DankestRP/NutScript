nut.command = nut.command or {}
nut.command.list = nut.command.list or {}

local COMMAND_PREFIX = "/"

-- Adds a new command to the list of commands.
function nut.command.add(command, data)
	-- For showing users the arguments of the command.
	data.syntax = data.syntax or "[none]"

	-- Why bother adding a command if it doesn't do anything.
	if (!data.onRun) then
		return ErrorNoHalt("Command '"..command.."' does not have a callback, not adding!\n")
	end

	-- Store the old onRun because we're able to change it.
	if (!data.onCheckAccess) then
		-- Check if the command is for basic admins only.
		if (data.adminOnly) then
			data.onCheckAccess = function(client)
				return client:IsAdmin()
			end
		-- Or if it is only for super administrators.
		elseif (data.superAdminOnly) then
			data.onCheckAccess = function(client)
				return client:IsSuperAdmin()
			end
		-- Or if we specify a usergroup allowed to use this.
		elseif (data.group) then
			-- The group property can be a table of usergroups.
			if istable(data.group) then
				data.onCheckAccess = function(client)
					-- Check if the client's group is allowed.
					for _, v in ipairs(data.group) do
						if (client:IsUserGroup(v)) then
							return true
						end
					end

					return false
				end
			-- Otherwise it is most likely a string.
			else
				data.onCheckAccess = function(client)
					return client:IsUserGroup(data.group)
				end
			end
		end
	end

	local onCheckAccess = data.onCheckAccess

	-- Only overwrite the onRun to check for access if there is anything to check.
	if (onCheckAccess) then
		local onRun = data.onRun

		data._onRun = data.onRun -- for refactoring purpose.
		data.onRun = function(client, arguments)
			if (hook.Run("CanPlayerUseCommand", client, command) or onCheckAccess(client)) then
				return onRun(client, arguments)
			else
				return "@noPerm"
			end
		end
	end

	-- Add the command to the list of commands.
	local alias = data.alias

	if (alias) then
		if istable(alias) then
			for _, v in ipairs(alias) do
				nut.command.list[v:lower()] = data
			end
		elseif isstring(alias) then
			nut.command.list[alias:lower()] = data
		end
	end

	if (command == command:lower()) then
		nut.command.list[command] = data
	else
		data.realCommand = command

		nut.command.list[command:lower()] = data
	end
end

-- Returns whether or not a player is allowed to run a certain command.
function nut.command.hasAccess(client, command)
	command = nut.command.list[command:lower()]

	if (command) then
		if (command.onCheckAccess) then
			return command.onCheckAccess(client)
		else
			return true
		end
	end

	return hook.Run("CanPlayerUseCommand", client, command) or false
end

-- Gets a table of arguments from a string.
function nut.command.extractArgs(text)
	local skip = 0
	local arguments = {}
	local curString = ""

	for i = 1, #text do
		if (i <= skip) then continue end

		local c = text:sub(i, i)

		if (c == "\"") then
			local match = text:sub(i):match("%b"..c..c)

			if (match) then
				curString = ""
				skip = i + #match
				arguments[#arguments + 1] = match:sub(2, -2)
			else
				curString = curString..c
			end
		elseif (c == " " and curString ~= "") then
			arguments[#arguments + 1] = curString
			curString = ""
		else
			if (c == " " and curString == "") then
				continue
			end

			curString = curString..c
		end
	end

	if (curString ~= "") then
		arguments[#arguments + 1] = curString
	end

	return arguments
end

if (SERVER) then
	-- Finds a player or gives an error notification.
	function nut.command.findPlayer(client, name)
		if isstring(name) then
			if name == "^" then -- thank you Hein/Hankshark - Tov
				return client
			elseif name == "@" then
				local trace = client:GetEyeTrace().Entity
				if IsValid(trace) and trace:IsPlayer() then
					return trace
				else
					client:notifyLocalized("lookToUseAt")
					return
				end
			end
			local target = nut.util.findPlayer(name) or NULL

			if (IsValid(target)) then
				return target
			else
				client:notifyLocalized("plyNoExist")
			end
		else
			client:notifyLocalized("mustProvideString")
		end
	end

	-- Finds a faction based on the uniqueID, and then the name if no such uniqueID exists.
	function nut.command.findFaction(client, name)
		if (nut.faction.teams[name]) then
			return nut.faction.teams[name]
		end

		for _, v in ipairs(nut.faction.indices) do
			if (nut.util.stringMatches(L(v.name,client), name)) then
				return v --This interrupt means we don't need an if statement below.
			end
		end

		client:notifyLocalized("invalidFaction")
	end

	-- Forces a player to run a command.
	function nut.command.run(client, command, arguments)
		local commandTbl = nut.command.list[command:lower()]

		if (commandTbl) then
			-- Run the command's callback and get the return.
			local results = {commandTbl.onRun(client, arguments or {})}
			local result = results[1]

			-- If a string is returned, it is a notification.
			if isstring(result) then
				-- Normal player here.
				if (IsValid(client)) then
					if (result:sub(1, 1) == "@") then
						client:notifyLocalized(result:sub(2), unpack(results, 2))
					else
						client:notify(result)
					end
				else
					-- Show the message in server console since we're running from RCON.
					print(result)
				end
			end

			if (IsValid(client)) then
				nut.log.add(client, "command", COMMAND_PREFIX .. command .. (#arguments > 0 and " " or "") .. table.concat(arguments, " "))
			end
		end
	end

	-- Add a function to parse a regular chat string.
	function nut.command.parse(client, text, realCommand, arguments)
		if (realCommand or text:utf8sub(1, 1) == COMMAND_PREFIX) then
			-- See if the string contains a command.
			local match = realCommand or text:lower():match(COMMAND_PREFIX.."([_%w]+)")

			-- is it unicode text?
			-- i hate unicode.
			if (!match) then
				local post = string.Explode(" ", text)
				local len = string.len(post[1])

				match = post[1]:utf8sub(2, len)
			end

			match = match:lower()

			local command = nut.command.list[match]
			-- We have a valid, registered command.
			if (command) then
				-- Get the arguments like a console command.
				if (!arguments) then
					arguments = nut.command.extractArgs(text:sub(#match + 3))
				end

				-- Runs the actual command.
				nut.command.run(client, match, arguments)
			else
				if (IsValid(client)) then
					client:notifyLocalized("cmdNoExist")
				else
					print("Sorry, that command does not exist.")
				end
			end

			return true
		end

		return false
	end

	concommand.Add("nut", function(client, _, arguments)
		local command = arguments[1]
		table.remove(arguments, 1)

		nut.command.parse(client, nil, command or "", arguments)
	end)

	netstream.Hook("cmd", function(client, command, arguments)
		if ((client.nutNextCmd or 0) < CurTime()) then
			local arguments2 = {}

			for _, v in ipairs(arguments) do
				if (isstring(v) or isnumber(v)) then
					arguments2[#arguments2 + 1] = tostring(v)
				end
			end

			nut.command.parse(client, nil, command, arguments2)
			client.nutNextCmd = CurTime() + 0.2
		end
	end)
else
	function nut.command.send(command, ...)
		netstream.Start("cmd", command, {...})
	end
end
