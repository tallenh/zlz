const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Visualizer = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    texture: *c.SDL_Texture,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*Visualizer {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            return error.SDLInitFailed;
        }

        const window = c.SDL_CreateWindow(
            "ZLZ Frame Viewer",
            @intCast(width),
            @intCast(height),
            c.SDL_WINDOW_RESIZABLE,
        ) orelse return error.WindowCreationFailed;

        const renderer = c.SDL_CreateRenderer(
            window,
            null,
        ) orelse return error.RendererCreationFailed;

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGBA8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(width),
            @intCast(height),
        ) orelse return error.TextureCreationFailed;

        const self = try allocator.create(Visualizer);
        self.* = .{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .width = width,
            .height = height,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *Visualizer) void {
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.allocator.destroy(self);
    }

    pub fn displayFrame(self: *Visualizer, frame_data: []const u8) !void {
        if (frame_data.len != self.width * self.height * 4) {
            return error.InvalidFrameSize;
        }

        _ = c.SDL_UpdateTexture(
            self.texture,
            null,
            frame_data.ptr,
            @intCast(self.width * 4),
        );

        _ = c.SDL_RenderClear(self.renderer);
        _ = c.SDL_RenderTexture(self.renderer, self.texture, null, null);
        _ = c.SDL_RenderPresent(self.renderer);
    }

    pub fn waitForInput() !void {
        var event: c.SDL_Event = undefined;
        while (true) {
            if (c.SDL_WaitEvent(&event)) {
                switch (event.type) {
                    c.SDL_EVENT_QUIT => return,
                    c.SDL_EVENT_KEY_DOWN => {
                        if (event.key.key == c.SDLK_ESCAPE) {
                            return;
                        }
                    },
                    else => {},
                }
            }
        }
    }
};
