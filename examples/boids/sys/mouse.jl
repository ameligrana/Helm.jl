install_mouse_handler = System(
    Res(Window),
    Res(WorldSize),
    ResMut(Mouse),
) do window, size, mouse
    on(window.scene.events.mouseposition) do mouse_position
        mouse.x = mouse_position[1]
        mouse.y = mouse_position[2]
        mouse.inside = contains(size, mouse.x, mouse.y)
    end
    return nothing
end
