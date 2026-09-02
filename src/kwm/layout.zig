const Self = @This();

pub const Type = enum {
    tile,
    grid,
    monocle,
    deck,
    scroller,
    centered_master,
    canvas,
    float,
};

pub const Tile = @import("layout/tile.zig");
pub const Grid = @import("layout/grid.zig");
pub const Monocle = @import("layout/monocle.zig");
pub const Deck = @import("layout/deck.zig");
pub const Scroller = @import("layout/scroller.zig");
pub const CenteredMaster = @import("layout/centered_master.zig");
pub const Canvas = @import("layout/canvas.zig");


tile: Tile,
grid: Grid,
monocle: Monocle,
deck: Deck,
    scroller: Scroller,
    centered_master: CenteredMaster,
    canvas: Canvas,
