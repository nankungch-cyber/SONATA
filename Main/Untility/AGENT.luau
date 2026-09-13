local _ENV = (getgenv or getrenv or getfenv)()

local Package, Settings = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/vita8it/Opengame/main/utils/package.luau"
))()

local Queue = Package.GoodQueue:Create()
local Plugins = Package.Plugins

local Saves, Cached = {}, {}
local PathCache = {}

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local FolderName = "Dump-" .. HttpService:GenerateGUID(false)

local DecompileQueue = {}
local MAX_WORKERS = 15
local ActiveWorkers = 0

local Blacklist = {}

local Allowed = {
	workspace,
	game.ReplicatedStorage,
	game.ReplicatedFirst,
	game.Lighting,
	game.StarterPlayer,
	game.StarterGui,
	game.Players,
}

Package:CreateModule("XynapseDumper", function(Module)
	local Dumper = {}

	function Dumper:IsAllowed(Object)
		for _, AllowedObject in Allowed do
			if Object == AllowedObject or Object:IsDescendantOf(AllowedObject) then
				return true
			end
		end

		return false
	end

	function Dumper:IsBlacklisted(Object)
		return Blacklist[Object.Name] == true
	end

	function Dumper:IsScript(Object)
		return Object:IsA("LocalScript") or Object:IsA("ModuleScript")
	end

	function Dumper:IsOwnScript(Object)
		if not self:IsScript(Object) or not LocalPlayer then
			return false
		end

		if not Object:IsDescendantOf(Players) then
			return true
		end

		return Object:IsDescendantOf(LocalPlayer)
	end

	function Dumper:SanitizeName(Name)
		Name = tostring(Name):gsub('[<>:"/\\|?*]', "_"):gsub("[%c]", "_"):gsub("[%. ]+$", "")

		if Name == "" then
			Name = "_"
		end

		local Reserved = {
			CON = true, PRN = true, AUX = true, NUL = true,
			COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true, COM6 = true, COM7 = true, COM8 = true, COM9 = true,
			LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true, LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
		}

		if Reserved[Name:upper()] then
			Name = "_" .. Name
		end

		return Name
	end

	function Dumper:CreateFolder(Path)
		if isfolder(Path) then
			return true
		end

		local Success, Result = pcall(makefolder, Path)

		if not Success then
			warn("[CreateFolder] Failed:", Path, Result)
			return false
		end

		return true
	end

	function Dumper:GetFolderPath(Object)
		if PathCache[Object] then
			return PathCache[Object]
		end

		local Parts = {}
		local Current = Object

		while Current and Current ~= game do
			table.insert(Parts, 1, self:SanitizeName(Current.Name))
			Current = Current.Parent
		end

		local Path = FolderName

		for _, Part in Parts do
			Path ..= "\\" .. Part
			self:CreateFolder(Path)
		end

		PathCache[Object] = Path
		return Path
	end

	function Dumper:BuildTree(Object)
		if self:IsBlacklisted(Object) then
			return nil
		end

		local Node = {
			Name = Object.Name,
			ClassName = Object.ClassName,
			Source = Object:GetFullName(),
			Children = {}
		}

		for _, Child in Object:GetChildren() do
			if not self:IsAllowed(Child) then
				continue
			end

			local ChildNode = self:BuildTree(Child)

			if ChildNode then
				Node.Children[#Node.Children + 1] = ChildNode
			end
		end

		return Node
	end

	function Dumper:TreeToString(Node, Prefix, IsLast)
		Prefix = Prefix or ""
		IsLast = IsLast == nil and true or IsLast

		local Result = {}

		if Node.Name == "game" then
			Result[#Result + 1] = Node.Name .. " : (" .. Node.ClassName .. ")"
		else
			local Branch = IsLast and "└── " or "├── "
			Result[#Result + 1] = Prefix .. Branch .. Node.Name .. " : (" .. Node.ClassName .. ")"
		end

		local Children = Node.Children
		local Count = #Children

		for Index, Child in Children do
			local Last = Index == Count
			local ChildPrefix

			if Node.Name == "game" then
				ChildPrefix = ""
			elseif IsLast then
				ChildPrefix = Prefix .. "    "
			else
				ChildPrefix = Prefix .. "│   "
			end

			local ChildResult = self:TreeToString(Child, ChildPrefix, Last)

			for Line in string.gmatch(ChildResult, "[^\n]+") do
				Result[#Result + 1] = Line
			end
		end

		return table.concat(Result, "\n")
	end

	function Dumper:SaveExplorer()
		Cached.Tree = {
			Name = "game",
			ClassName = "DataModel",
			Source = "game",
			Children = {}
		}

		for _, Object in Allowed do
			local Node = self:BuildTree(Object)

			if Node then
				Cached.Tree.Children[#Cached.Tree.Children + 1] = Node
			end
		end

		Dumper.Tree = self:TreeToString(Cached.Tree)

		local Success, Error = pcall(writefile, FolderName .. "\\Explorer.txt", Dumper.Tree)

		if not Success then
			warn("[Explorer] Failed:", Error)
		end
	end

	function Dumper:CollectScripts()
		Cached.Builder.Scripts = {}

		for _, Object in game:GetDescendants() do
			if not self:IsScript(Object) or not self:IsAllowed(Object) or not self:IsOwnScript(Object) or self:IsBlacklisted(Object) then
				continue
			end

			local Parent = Object.Parent

			if not Parent then
				continue
			end

			local FilePath = self:GetFolderPath(Parent) .. "\\" .. self:SanitizeName(Object.Name) .. ".lua"

			Cached.Builder.Scripts[#Cached.Builder.Scripts + 1] = {
				Name = Object.Name,
				ClassName = Object.ClassName,
				Path = Object:GetFullName(),
				File = FilePath
			}
		end
	end

	function Dumper:ProcessQueue()
		if ActiveWorkers >= MAX_WORKERS then
			return
		end

		while #DecompileQueue > 0 and ActiveWorkers < MAX_WORKERS do
			ActiveWorkers += 1
			local Task = table.remove(DecompileQueue, 1)

			task.spawn(function()
				local Success, Source = pcall(decompile, Task.Object)

				if not Success or type(Source) ~= "string" then
					if Task.Retries > 0 then
						task.wait(0.5)
						table.insert(DecompileQueue, { Object = Task.Object, FilePath = Task.FilePath, Retries = Task.Retries - 1 })
					else
						warn("[Decompile] Exhausted retries for:", Task.Object:GetFullName())
					end
				else
					local WriteSuccess, WriteError = pcall(writefile, Task.FilePath, Source)

					if WriteSuccess then
						print("[Decompile] Saved:", Task.Object:GetFullName())
					else
						warn("[WriteFile] Failed:", Task.FilePath, WriteError)
					end
				end

				ActiveWorkers -= 1
				self:ProcessQueue()
			end)
		end
	end

	function Dumper:QueueScriptSave(Object, FilePath)
		table.insert(DecompileQueue, {
			Object = Object,
			FilePath = FilePath,
			Retries = 3
		})

		self:ProcessQueue()
	end

	function Dumper:SaveScript(Object)
		if not self:IsScript(Object) or not self:IsAllowed(Object) or not self:IsOwnScript(Object) or self:IsBlacklisted(Object) then
			return
		end

		local Parent = Object.Parent

		if not Parent then
			return
		end

		local FolderPath = self:GetFolderPath(Parent)
		local FilePath = FolderPath .. "\\" .. self:SanitizeName(Object.Name) .. ".lua"

		self:QueueScriptSave(Object, FilePath)
	end

	function Dumper:BuildFilesystem(Object)
		if self:IsBlacklisted(Object) then
			return
		end

		if self:IsScript(Object) then
			self:SaveScript(Object)
		end

		for _, Child in Object:GetChildren() do
			if self:IsAllowed(Child) then
				self:BuildFilesystem(Child)
			end
		end
	end

	function Dumper:Build()
		Cached.Builder = { Name = FolderName, Explorer = nil, Scripts = {} }

		if not self:CreateFolder(FolderName) then
			error("Unable to create dump folder: " .. FolderName)
		end

		print("[Dump] Folder:", FolderName)

		self:SaveExplorer()
		Cached.Builder.Explorer = Dumper.Tree

		for _, Object in Allowed do
			self:BuildFilesystem(Object)
		end

		self:CollectScripts()

		return Cached.Builder
	end

	return Dumper
end)

local XynapseDumper = Package.XynapseDumper
local Builder = XynapseDumper:Build()

local Folder = gethui and gethui()

for Index, Value in Folder:GetChildren() do
	if Value.Name:find("Next.js") then
		Value:Destroy()
	end
end

Window:Community()

local Tab = Plugins:CreateTab({
	"Main",
	"Xynapse Dumper Controls"
}) do
	Tab:Section("Dumper", function(Section)
		Plugins:SetDefault("AutoDump", false)

		Queue:CreateOption("Auto Dump System", function()
			print("Running Auto Dump Thread")
		end, 1)

		Plugins:Toggle(Section, {
			"Auto Dump",
			"Automatically check and dump scripts"
		}, "AutoDump", function(Value)
			print("Auto Dump:", Value)
		end)
	end)
end

Window:Managers()
Queue:StartQueue()

print("================================")
print("    Discord: https://discord.gg/Hra9Ea9C7")
print("================================")
print("Folder:", FolderName)
print("Scripts:", #Builder.Scripts)
print("Explorer: Saved")
print("Workers Array:", MAX_WORKERS, "Threads")
print("================================")

return Builder
