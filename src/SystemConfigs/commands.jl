"""
    Cmds(specifications)

Describe an Ark command buffer injected into a [`System`](@ref).
`specifications` is a tuple of Ark command spec constructors, exactly as
accepted by `Ark.CommandBuffer`:

```julia
Cmds((
    Ark.NewEntityCommand((Position, Velocity)),
    Ark.RemoveEntityCommand(),
    Ark.AddComponentsCommand((Health,)),
))
```

Helm applies the buffer after the system returns and conservatively serializes
command-buffer systems against other systems.
"""
struct Cmds{S<:Tuple{Vararg{Val}}} <: SystemConfig end

function Cmds(specs::Tuple)
    isempty(specs) && throw(
        ArgumentError("command buffer needs to contain at least one deferred operation")
    )
    for spec in specs
        spec isa Type ||
            throw(ArgumentError("command specifications must be types, got $(spec)"))
    end
    return Cmds{typeof(_valtuple(specs))}()
end

reads(::Cmds) = ()
writes(::Cmds) = ()
reads(::Type{<:Cmds}) = ()
writes(::Type{<:Cmds}) = ()

@inline @generated function _valtuple(t::Tuple{Vararg{Any,N}}) where {N}
    exprs = Expr[:(Val(getfield(t, $i))) for i in 1:N]
    return Expr(:tuple, exprs...)
end

_val_parameter(::Type{Val{T}}) where {T} = T

@generated function to_command_buffer(world::W, ::Cmds{S}) where {W<:Ark.World,S<:Tuple}
    spec_types = DataType[_val_parameter(parameter) for parameter in S.parameters]
    specs = Expr(:tuple, spec_types...)
    return :(Ark.CommandBuffer(world, $specs))
end
