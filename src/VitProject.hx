package;
import haxe.CallStack;
import haxe.Json;
import haxe.io.Path;
import yy.*;
import sys.FileSystem;
import sys.io.File;
import tools.Alias;
import tools.SfGmx;
import vit.*;
import tools.StringBuilder;
import tools.SysTools;
import yy.YyProject;
import rules.*;

/**
 * ...
 * @author YellowAfterlife
 */
class VitProject {
	public static var current:VitProject;
	public var isOK = false;
	public var objectNames:Map<YyGUID, Ident> = new Map();
	public var spriteNames:Map<YyGUID, Ident> = new Map();
	public var gameSpeed:Int = 60;
	public var tilesetInit:StringBuilder = new StringBuilder();
	public var tilesets:Map<YyGUID, VitTileset> = new Map();
	public var noExport:Map<YyGUID, Bool> = new Map();
	public var nextTileIndex:Int = 10000001;
	public var audioGroupIDs:Map<YyGUID, Int> = new Map();
	public var audioGroupNames:Array<Ident> = [];
	public var textureGroupIDs:Map<YyGUID, Int> = new Map();
	public var spriteSpeedBuf:StringBuilder = new StringBuilder();
	
	/** "func_name" -> true */
	public var apiUses:Map<Ident, Bool> = new Map();
	
	//
	public var folders:Map<YyGUID, YyView> = new Map();
	public var rootView:YyView = null;
	
	public var assets:Map<YyGUID, YyProjectResource> = new Map();
	private var assetDataCache:Map<YyGUID, {val:Dynamic}> = new Map();
	/** Asset ID -> Asset JSON */
	public function getAssetData(id:YyGUID):Dynamic {
		var ctr = assetDataCache[id];
		if (ctr == null) {
			var pair = assets[id];
			var path = pair.Value.resourcePath;
			var value:Dynamic = null;
			try {
				var rt = pair.Value.resourceType;
				var text = File.getContent(projectDir + '/' + path);
				if (rt == GMExtension) {
					text = ~/(\n[ \t]*"copyToTargets":[ \t]*)(\d+)([\r\n,])/g
						.replace(text, '$1"$2"$3');
				}
				value = Json.parse(text);
			} catch (x:Dynamic) {
				Sys.println('Failed to get asset data for $path: $x');
			}
			ctr = {val:value};
			assetDataCache[id] = ctr;
		}
		return ctr.val;
	}
	
	private var assetTextCache:Map<FullPath, String> = new Map();
	public function getAssetText(path:FullPath):String {
		var text = assetTextCache[path];
		if (text == null) {
			try {
				text = File.getContent(path);
			} catch (x:Dynamic) {
				text = "";
				Sys.println('Failed to get asset text for $path: $x');
			}
			assetTextCache[path] = text;
		}
		return text;
	}
	
	public inline function fullPath(path:RelPath):FullPath {
		return projectDir + "/" + path;
	}
	
	//
	public var project:YyProject;
	public var projectPath:FullPath;
	public var projectDir:FullPath;
	//
	public var outPath:FullPath;
	public var outName:String;
	public var outDir:FullPath;
	//
	public function new(from:String) {
		projectPath = from;
		var dir = Path.directory(from);
		projectDir = dir;
		SysTools.blockStart("Loading project");
		project = try {
			Json.parse(File.getContent(from));
		} catch (x:Dynamic) {
			Sys.println("");
			Sys.println("Either this is a 2.3 project or JSON is malformed: " + x);
			return;
		};
		//
		for (pair in project.resources) {
			var id = pair.Key;
			if (pair.Value.resourceType == GMFolder) {
				var fd:YyView = Json.parse(File.getContent(Path.join([dir, "views", '$id.yy'])));
				folders[id] = fd;
				if (fd.isDefaultView) rootView = fd;
			} else {
				assets[id] = pair;
				var path = pair.Value.resourcePath;
				var name = Path.withoutDirectory(Path.withoutExtension(path));
				pair.Value.resourceName = name;
				switch (pair.Value.resourceType) {
					case GMObject: objectNames[id] = name;
					case GMSprite: spriteNames[id] = name;
					default: 
				};
			}
		}
		//
		try {
			var fakeJson = File.getContent(dir + "/options/main/inherited/options_main.inherited.yy");
			var rxSp = ~/"option_game_speed": ([-\d.]+)/;
			if (rxSp.match(fakeJson)) {
				gameSpeed = Std.parseInt(rxSp.matched(1));
			}
		} catch (_:Dynamic) {};
		//
		SysTools.blockEnd();
		isOK = true;
	}
	public function index():Void {
		SysTools.blockStart("Indexing");
		for (pair in project.resources) switch (pair.Value.resourceType) {
			#if !gmv_nc
			case GMTileSet: {
				var yy = getAssetData(pair.Key);
				if (yy != null) VitTileset.pre(pair.Value.resourceName, yy);
			};
			case GMSprite: {
				var yy = getAssetData(pair.Key);
				if (yy != null) VitSprite.pre(pair.Value.resourceName, yy);
			};
			#end
			case GMScript: {
				var yyScript:YyScript = getAssetData(pair.Key);
				if (yyScript != null && !yyScript.IsCompatibility) {
					VitGML.index(
						getAssetText(fullPath(pair.Value.resourcePath)),
						pair.Value.resourceName
					);
				}
			};
			case GMObject: {
				var yyObject:YyObject = getAssetData(pair.Key);
				if (yyObject != null) {
					VitObject.index(
						pair.Value.resourceName,
						yyObject, 
						fullPath(pair.Value.resourcePath)
					);
				}
			};
			default:
		}
		SysTools.blockEnd();
	}
	public function print(to:String) {
		current = this;
		//
		outPath = to;
		outName = Path.withoutDirectory(outPath);
		for (_ in 0 ... 2) outName = Path.withoutExtension(outName);
		var dir = Path.directory(to);
		outDir = dir;
		if (!FileSystem.exists(outDir)) FileSystem.createDirectory(outDir);
		//
		Sys.println("Printing...");
		var gmx = new SfGmx("assets"), q:SfGmx;
		//{ prepare GMX
		function addCat(kind:String, label:String):SfGmx {
			var q = gmx.addEmptyChild(kind);
			q.set("name", label);
			return q;
		}
		q = addCat("Configs", "configs");
		q.addTextChild("Config", "Configs\\Default");
		var datafiles = addCat("datafiles", "datafiles");
		var datafileCount = 0;
		var extensions = gmx.addEmptyChild("NewExtensions");
		addCat("sounds", "sound");
		addCat("sprites", "sprites");
		addCat("backgrounds", "background");
		addCat("paths", "paths");
		addCat("scripts", "scripts");
		addCat("shaders", "shaders");
		addCat("fonts", "fonts");
		addCat("objects", "objects");
		addCat("timelines", "timelines");
		addCat("rooms", "rooms");
		var macros = gmx.addEmptyChild("constants");
		macros.setInt("number", 0);
		gmx.addEmptyChild("help");
		//
		var audioGroups = addCat("audiogroups", "audiogroups");
		//
		q = gmx.addEmptyChild("TutorialState");
		q.addTextChild("IsTutorial", "0");
		q.addTextChild("TutorialName", "");
		q.addTextChild("TutorialPage", "0");
		//}
		//{ prepare directories
		var dir = Path.directory(to);
		SysTools.ensureDirectory(dir);
		SysTools.ensureDirectory('$dir/Configs');
		SysTools.ensureDirectory('$dir/sprites');
		SysTools.ensureDirectory('$dir/sprites/images');
		SysTools.ensureDirectory('$dir/sound');
		SysTools.ensureDirectory('$dir/sound/audio');
		SysTools.ensureDirectory('$dir/background');
		SysTools.ensureDirectory('$dir/background/images');
		SysTools.ensureDirectory('$dir/paths');
		SysTools.ensureDirectory('$dir/scripts');
		SysTools.ensureDirectory('$dir/shaders');
		SysTools.ensureDirectory('$dir/fonts');
		SysTools.ensureDirectory('$dir/timelines');
		SysTools.ensureDirectory('$dir/objects');
		SysTools.ensureDirectory('$dir/rooms');
		SysTools.ensureDirectory('$dir/datafiles');
		SysTools.ensureDirectory('$dir/extensions');
		//}
		VitProjectOptions.proc(this);
		//{ prepare assets
		for (augName in audioGroupNames) {
			audioGroups.addEmptyChild("audiogroup").set("name", augName);
		}
		//
		index();
		//}
		if (spriteSpeedBuf.length > 0) apiUses["sprite_speed"] = true;
		Ruleset.init();
		//
		function addAssetNode(chain:Array<String>, gmxItem:SfGmx, plural:String, before:Bool = false):Void {
			var gmxDir = gmx;
			for (part in chain) {
				var gmxNext:SfGmx = null;
				for (gmxChild in gmxDir.children) {
					if (gmxChild.get("name") == part) {
						gmxNext = gmxChild;
						break;
					}
				}
				if (gmxNext == null) {
					gmxNext = new SfGmx(plural);
					gmxNext.set("name", part);
					if (before) {
						gmxDir.insertBefore(gmxNext, gmxDir.children[0]);
					} else gmxDir.addChild(gmxNext);
				}
				gmxDir = gmxNext;
			}
			//
			gmxDir.addChild(gmxItem);
		}
		function printAsset(pair:YyProjectResource, chain:Array<String>):Void {
			var id = pair.Key;
			if (noExport[id]) return;
			var yyType = pair.Value.resourceType;
			var single = yyType.toString().substring(2).toLowerCase();
			var path = pair.Value.resourcePath;
			var name = Path.withoutDirectory(Path.withoutExtension(path));
			//
			if (single == "includedfile") {
				single = "datafile";
			} else if (single == "tileset") {
				single = "background";
				chain = chain.copy();
				chain[0] = "background";
				name = VitTileset.prefix + name;
			} else if (single == "sprite") {
				var isBg = false;
				for (rx in Params.backgroundRegex) {
					if (rx.match(name)) { isBg = true; break; }
				}
				if (isBg) {
					single = "background";
					chain = chain.copy();
					chain[0] = "background";
				}
			}
			var plural = single + "s";
			//
			var gmxPath = switch (single) {
				case "sound", "background": '$single\\$name';
				default: '$plural\\$name';
			};
			switch (single) {
				case "script": gmxPath += ".gml";
				case "shader": gmxPath += ".shader";
			};
			//
			var yyPath = pair.Value.resourcePath;
			var yyFull = Path.join([projectDir, yyPath]);
			var yy:Dynamic = getAssetData(id);
			if (yy == null) {
				trace("no data for " + yyFull);
				return;
			}
			var outPath = Path.join([dir, gmxPath]);
			var gmxItem = new SfGmx(single, gmxPath);
			//
			switch (single) {
				case "script": {
					var scr:YyScript = yy;
					if (scr.IsCompatibility) return;
					Sys.println('Converting $name...');
					var gml = try {
						File.getContent(Path.withExtension(yyFull, "gml"));
					} catch (x:Dynamic) {
						Sys.println('Failed to read $yyFull: $x');
						"";
					}
					File.saveContent(outPath, VitGML.proc(gml, name));
				};
				case "datafile": chain = chain.copy(); chain[0] = "datafiles"; datafileCount++;
					        VitIncludedFile.proc(name, yy, yyFull, outPath, gmxItem, chain);
				case "sprite":    VitSprite.proc(name, yy, yyFull, outPath);
				case "font":        VitFont.proc(name, yy, yyFull, outPath);
				case "path":   VitPointPath.proc(name, yy, yyFull, outPath);
				case "sound":      VitSound.proc(name, yy, yyFull, outPath);
				case "object":    VitObject.proc(name, yy, yyFull, outPath);
				case "room":        VitRoom.proc(name, yy, yyFull, outPath);
				case "background": switch (yyType) {
					case GMTileSet: VitTileset.proc(name, tilesets[id], yyFull, outPath);
					case GMSprite:   VitSprite.procBg(name, yy, yyFull, outPath);
					default:
				};
				case "shader": {
					var sh:YyShader = yy;
					var fsh = File.getContent(Path.withExtension(yyFull, "fsh"));
					var vsh = File.getContent(Path.withExtension(yyFull, "vsh"));
					var m = "\r\n//######################_==_YOYO_SHADER_MARKER_==_######################@~";
					File.saveContent(outPath, vsh + m + fsh);
					gmxItem.set("type", switch (sh.type) {
						case 1: "GLSLES";
						case 4: "HLSL11";
						default: "GLSL";
					});
				};
				case "extension": {
					VitExtension.proc(name, yy, yyFull, outPath);
					gmxItem.setInt("index", extensions.children.length);
					extensions.addChild(gmxItem);
					gmxItem = null;
				};
				default: return;
			}
			//
			if (gmxItem != null) addAssetNode(chain, gmxItem, plural);
			//trace(pair.Value.resourcePath, single, chain);
		}
		function printFolder(fd:YyView, chain:Array<String>):Void {
			for (id in fd.children) {
				var fd1 = folders[id];
				if (fd1 != null) {
					var next:Array<String>;
					if (chain != null) {
						next = chain.copy();
						next.push(fd1.folderName);
					} else next = [];
					printFolder(fd1, next);
					continue;
				}
				var pair = assets[id];
				if (pair != null) {
					printAsset(pair, chain);
					continue;
				}
				// ..?
			}
		}
		printFolder(rootView, []);
		datafiles.setInt("number", datafileCount);
		//
		if (tilesetInit.length > 0) {
			var imp = new ImportRule("gmv_tileset_init", null, Script);
			imp.data = 'gml_pragma("global", "gmv_tileset_init()");\r\n' + tilesetInit.toString();
			imp.data = VitGML.proc(imp.data, "gmv_tileset_init"); // to trigger imports
			Ruleset.importList.unshift(imp);
		}
		//
		if (spriteSpeedBuf.length > 0) {
			var spb = new StringBuilder();
			spb.addFormat('gml_pragma("global", "gmv_sprite_speed_init()");\r\n');
			spb.addFormat("var l_data = ds_list_create();\r\n");
			spb.addString(spriteSpeedBuf.toString());
			spb.addString("var l_count = ds_list_size(l_data);\r\n");
			spb.addString("var l_max = 0;\r\n");
			spb.addString("for (var l_i = 0; l_i < l_count; l_i += 2) "
				+ "l_max = max(l_max, l_data[|l_i]);\r\n");
			spb.addString("l_max++;\r\n");
			spb.addString("globalvar sprite_speed_array_size;\r\n");
			spb.addString("sprite_speed_array_size = l_max;\r\n");
			spb.addString("globalvar sprite_speed_array;\r\n");
			spb.addString("sprite_speed_array = array_create(l_max);\r\n");
			spb.addString("while (--l_max >= 0) sprite_speed_array[l_max] = 1;\r\n");
			spb.addString("for (var l_i = 0; l_i < l_count; l_i += 2) "
				+ "sprite_speed_array[l_data[|l_i]] = l_data[|l_i + 1];\r\n");
			var imp = new ImportRule("gmv_sprite_speed_init", null, Script);
			imp.data = spb.toString();
			Ruleset.importList.unshift(imp);
		};
		//trace(Ruleset.importList.length); Sys.getChar(true);
		for (imp in Ruleset.importList) {
			var name = imp.name;
			Sys.println('Importing $name...');
			switch (imp.kind) {
				case Script: {
					var dest = '$dir\\scripts\\$name.gml';
					if (imp.data != null) {
						File.saveContent(dest, imp.data);
					} else File.copy(imp.path, dest);
					addAssetNode(
						["scripts", "GMS2 compatibility"],
						new SfGmx("script", 'scripts\\$name.gml'),
						"scripts", true);
				};
				case Object: {
					var dest = '$dir\\objects\\$name.object.gmx';
					if (imp.data != null) {
						File.saveContent(dest, imp.data);
					} else File.copy(imp.path, dest);
					addAssetNode(
						["objects", "GMS2 compatibility"],
						new SfGmx("object", 'objects\\$name'),
						"objects", true);
				};
				case Extension: {
					var extNode = new SfGmx("extension", 'extensions\\$name');
					extNode.setInt("index", extensions.children.length);
					extensions.addChild(extNode);
					//
					File.saveContent('$dir\\extensions\\$name.extension.gmx', imp.data);
					var extRoot = imp.gmxData;
					var extInDir = Path.directory(imp.path) + '\\$name';
					var extOutDir = '$dir\\extensions\\$name';
					if (!FileSystem.exists(extOutDir)) FileSystem.createDirectory(extOutDir);
					for (extFile in extRoot.find("files").findAll("file")) {
						var fname = extFile.findText("filename");
						try {
							File.copy(extInDir + '/' + fname, extOutDir + '/' + fname);
						} catch (x:Dynamic) {
							trace('Failed to copy $name:$fname: $x');
						}
					}
				};
				default: Sys.println('Can\'t import ${imp.kind} yet (for $name)');
			}
		}
		//
		var defaultMacros = 0;
		for (m in VitGML.macroList) {
			if (m.config != null) continue;
			var c = macros.addTextChild("constant", m.value);
			c.set("name", m.name);
			defaultMacros++;
		}
		macros.setInt("number", defaultMacros);
		//
		Sys.println("Saving project...");
		File.saveContent(to, gmx.toGmxString());
	}
	public static function proc(from:String, to:String) {
		var pj = new VitProject(from);
		if (pj.isOK) pj.print(to);
	}
}
