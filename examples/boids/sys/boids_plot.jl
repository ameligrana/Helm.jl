update_plot = System(
    ResMut(PlotData),
    Query((Const(Position), Const(Rotation))),
) do data, query
    positions_data = data.positions[]
    rotations_data = data.rotations[]
    empty!(positions_data)
    empty!(rotations_data)

    for (_, positions, rotations) in query
        append!(positions_data, getfield.(positions, :p))
        append!(rotations_data, getfield.(rotations, :r))
    end

    notify(data.positions)
    notify(data.rotations)
    return nothing
end
