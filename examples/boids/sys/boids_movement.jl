struct BoidsMovement
  avoid_factor::Float64
  avoid_distance::Float64
  align_factor::Float64
  cohesion_factor::Float64
  min_speed::Float64
  max_speed::Float64
  margin::Float64
  margin_factor::Float64
  mouse_radius::Float64
  mouse_avoid_factor::Float64
end

function BoidsMovement(;
  avoid_factor::Float64,
  avoid_distance::Float64,
  align_factor::Float64,
  cohesion_factor::Float64,
  min_speed::Float64,
  max_speed::Float64,
  margin::Float64,
  margin_factor::Float64,
  mouse_radius::Float64,
  mouse_avoid_factor::Float64,
)
  return BoidsMovement(
    avoid_factor,
    avoid_distance,
    align_factor,
    cohesion_factor,
    min_speed,
    max_speed,
    margin,
    margin_factor,
    mouse_radius,
    mouse_avoid_factor,
  )
end

update_movement = System(
  Res(BoidsMovement),
  Res(WorldSize),
  Res(Mouse),
  Query((Position, Velocity, Neighbors)),
) do settings, size, mouse, query
  avoid_distance_sq = settings.avoid_distance * settings.avoid_distance
  mouse_distance_sq = settings.mouse_radius * settings.mouse_radius

  for (entities, positions, velocities, neighbors) in query
    for i in eachindex(entities, positions, velocities, neighbors)
      entity = entities[i]
      position = positions[i].p
      velocity = velocities[i].v

      close_x, close_y = 0.0, 0.0
      average_x, average_y = 0.0, 0.0
      average_vx, average_vy = 0.0, 0.0
      neighbor_count = 0

      for neighbor in neighbors[i].n
        has_components(query, neighbor, (Position, Velocity)) || continue
        other_position, other_velocity =
          get_components(query, neighbor, (Position, Velocity))
        distance = distance_sq(position, other_position.p)
        if distance <= avoid_distance_sq
          close_x += position[1] - other_position.p[1]
          close_y += position[2] - other_position.p[2]
        end
        average_x += other_position.p[1]
        average_y += other_position.p[2]
        average_vx += other_velocity.v[1]
        average_vy += other_velocity.v[2]
        neighbor_count += 1
      end

      vx, vy = velocity[1], velocity[2]
      if neighbor_count > 0
        average_x /= neighbor_count
        average_y /= neighbor_count
        average_vx /= neighbor_count
        average_vy /= neighbor_count
        close_x, close_y = normalize(close_x, close_y)

        vx += close_x * settings.avoid_factor +
              (average_vx - velocity[1]) * settings.align_factor +
              (average_x - position[1]) * settings.cohesion_factor
        # Preserve the original example's Y-alignment-against-X quirk.
        vy += close_y * settings.avoid_factor +
              (average_vy - velocity[1]) * settings.align_factor +
              (average_y - position[2]) * settings.cohesion_factor
      end

      if mouse.inside
        distance = distance_sq(Point2f(mouse.x, mouse.y), position)
        if distance < mouse_distance_sq
          factor = 1 - sqrt(distance) / settings.mouse_radius
          dx, dy = normalize(position[1] - mouse.x, position[2] - mouse.y)
          # Preserve the original use of avoid_factor here.
          vx += dx * settings.avoid_factor * factor
          vy += dy * settings.avoid_factor * factor
        end
      end

      if position[1] < settings.margin
        factor = 1 - position[1] / settings.margin
        vx += settings.margin_factor * factor * factor
      elseif position[1] > size.width - settings.margin
        factor = 1 - (size.width - position[1]) / settings.margin
        vx -= settings.margin_factor * factor * factor
      end
      if position[2] < settings.margin
        factor = 1 - position[2] / settings.margin
        vy += settings.margin_factor * factor * factor
      elseif position[2] > size.height - settings.margin
        factor = 1 - (size.height - position[2]) / settings.margin
        vy -= settings.margin_factor * factor * factor
      end

      speed = sqrt(vx * vx + vy * vy)
      if speed < settings.min_speed
        vx = vx / speed * settings.min_speed
        vy = vy / speed * settings.min_speed
      elseif speed > settings.max_speed
        vx = vx / speed * settings.max_speed
        vy = vy / speed * settings.max_speed
      end

      set_components!(
        query,
        entity,
        (
          Position(Point2f(position[1] + vx, position[2] + vy)),
          Velocity(Point2f(vx, vy)),
        ),
      )
    end
  end
  return nothing
end

update_rotations = System(Query((Const(Velocity), Rotation))) do query
  for (entities, velocities, _) in query
    for i in eachindex(entities, velocities)
      set_components!(
        query,
        entities[i],
        (Rotation(direction_to_rotation(velocities[i].v)),),
      )
    end
  end
  return nothing
end
