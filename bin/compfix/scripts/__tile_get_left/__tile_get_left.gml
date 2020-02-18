/// @param tile
var _tile = argument0;

var l_region = global.__tile_regions[?_tile];
if (l_region == undefined) {
	l_region = layer_tile_get_region(_tile);
	if (array_length_1d(l_region)) {
		global.__tile_regions[?_tile] = l_region;
	} else return 0;
}
return l_region[0];