abstract type AbstractCommand end

struct Cmds{N,T<:Tuple{Vararg{AbstractCommand,N}}} <: SystemConfig end


Cmds(t::T) where {N,T<:Tuple{Vararg{AbstractCommand,N}}} = Cmds{N,T}()


struct NewEntity{V<:Tuple} <: AbstractCommand end
struct RemoveEntity <: AbstractCommand end
struct AddComponents{C<:Tuple} <: AbstractCommand end
struct RemoveComponents{R<:Tuple} <: AbstractCommand end
struct ExchangeComponents{A<:Tuple,R<:Tuple} <: AbstractCommand end
struct SetComponents{V<:Tuple} <: AbstractCommand end
struct SetRelations{R<:Tuple} <: AbstractCommand end

reads(::Cmds) = ()
writes(::Cmds) = ()
reads(::Type{Cmds}) = ()
writes(::Type{Cmds}) = ()

@generated function to_command_buffer(world::W, ::Cmds{N,T}) where {W<:Ark.World,N,T<:Tuple}
    ark_specs = Expr[]

    for helm_cmd_type in T.parameters
        if helm_cmd_type <: NewEntity
            values = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            push!(ark_specs, :(Ark.NewEntityCommand($values)))
        elseif helm_cmd_type <: RemoveEntity
            push!(ark_specs, :(Ark.RemoveEntityCommand()))
        elseif helm_cmd_type <: AddComponents
            values = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            push!(ark_specs, :(Ark.AddComponentsCommand($values)))
        elseif helm_cmd_type <: RemoveComponents
            values = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            push!(ark_specs, :(Ark.RemoveComponentsCommand($values)))
        elseif helm_cmd_type <: ExchangeComponents
            add = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            remove = Expr(:tuple, helm_cmd_type.parameters[2].parameters...)
            push!(ark_specs, :(Ark.ExchangeComponentsCommand(add=$add, remove=$remove)))
        elseif helm_cmd_type <: SetComponents
            values = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            push!(ark_specs, :(Ark.SetComponentsCommand($values)))
        elseif helm_cmd_type <: SetRelations
            values = Expr(:tuple, helm_cmd_type.parameters[1].parameters...)
            push!(ark_specs, :(Ark.SetRelationsCommand($values)))
        end
    end

    specs = Expr(:tuple, ark_specs...)
    return :(Ark.CommandBuffer(world, $specs))
end


@inline @generated function _valtuple(t::Tuple{Vararg{Any,N}}) where {N}
  exprs = Expr[:(Val(getfield(t, $i))) for i in 1:N]
  return Expr(:tuple, exprs...)
end

_val_parameter(::Type{Val{T}}) where {T} = T

function _extract_component_types(VT::Type{<:Tuple})
  component_types = ntuple(i -> _val_parameter(fieldtype(VT, i)), Val(fieldcount(VT)))
  return Tuple{component_types...}
end


function _spec_command_type(spec::Tuple{typeof(Ark.new_entity!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])            # (Val{Int}(), Val{Float64}())
  VT = typeof(val_tuple)                    # Tuple{Val{Int}, Val{Float64}}
  return NewEntity{_extract_component_types(VT)}
end

_spec_command_type(::Tuple{typeof(Ark.remove_entity!)}) = RemoveEntity

function _spec_command_type(spec::Tuple{typeof(Ark.add_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return AddComponents{_extract_component_types(VT)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.remove_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return RemoveComponents{_extract_component_types(VT)}
end

function _spec_command_type(
  spec::Tuple{typeof(Ark.exchange_components!),NamedTuple{(:add, :remove),<:Tuple{A,R}}}
) where {A<:Tuple,R<:Tuple}
  add_val_tuple = _valtuple(spec[2].add)
  remove_val_tuple = _valtuple(spec[2].remove)
  VT_add = typeof(add_val_tuple)
  VT_rem = typeof(remove_val_tuple)
  return ExchangeComponents{_extract_component_types(VT_add),_extract_component_types(VT_rem)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.set_components!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  return SetComponents{_extract_component_types(VT)}
end

function _spec_command_type(spec::Tuple{typeof(Ark.set_relations!),T}) where {T<:Tuple}
  val_tuple = _valtuple(spec[2])
  VT = typeof(val_tuple)
  # set_relations! expects relation types directly, no wrapping
  return SetRelations{_extract_component_types(VT)}
end

_spec_command_type(x) = throw(ArgumentError("unknown command specification: $x"))


function _specs_to_types(specs::Tuple)
  length(specs) == 0 && throw(
    ArgumentError("command buffer needs to contain at least one deferred operation")
  )

  types = Vector{Type}(undef, length(specs))

  @inbounds for i in eachindex(specs)
    types[i] = _spec_command_type(specs[i])
  end

  return Tuple(types)
end

function Cmds(specs::Tuple)
  n = length(specs)

  n == 0 && throw(
    ArgumentError("command buffer needs to contain at least one deferred operation")
  )

  types = Vector{Type}(undef, n)

  @inbounds for i in eachindex(specs)
    types[i] = _spec_command_type(specs[i])
  end

  T = Tuple{types...}

  return Cmds{n,T}()
end
