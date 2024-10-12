const raylib = @import("raylib");

pub fn main() !void {
	const width = raylib.getScreenWidth();
	const height = raylib.getScreenHeight();

	raylib.initWindow(width, height, "Goons TD");
	defer raylib.closeWindow();

	raylib.setExitKey(.key_null);

	raylib.setWindowFocused();
	raylib.setTargetFPS(120);

	while (!raylib.windowShouldClose()) {
		raylib.beginDrawing();
		raylib.clearBackground(raylib.Color.ray_white);
		raylib.endDrawing();
	}
}
