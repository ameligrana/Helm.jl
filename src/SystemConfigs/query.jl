struct QueryData{R,W,WI,WO,O} <: SystemConfig end
struct Const{T} end

function Const(::Type{T}) where {T}
    if !isbitstype(T)
        throw(ArgumentError("A component can be marked constant only if immutable."))
    end

    return Const{T}
end

_unwrap_comp(::Type{T}) where {T} = (T, :write)
_unwrap_comp(::Type{Const{T}}) where {T} = (T, :read)

_sort_comps(::Tuple{}, reads::Tuple, writes::Tuple) = (reads, writes)

function _sort_comps(comps::Tuple, reads::Tuple, writes::Tuple)
  head = comps[1]
  tail = Base.tail(comps)

  T, mode = _unwrap_comp(head)

  if mode === :read
    return _sort_comps(tail, (reads..., T), writes)
  else
    return _sort_comps(tail, reads, (writes..., T))
  end
end

function separate_reads_and_writes(comps::Tuple)
  return _sort_comps(comps, (), ())
end

function Query(comps::Tuple; with=(), without=())
  R, W = separate_reads_and_writes(comps)
  return QueryData{
    Tuple{R...},
    Tuple{W...},
    Tuple{with...},
    Tuple{without...},
    Tuple{comps...},
  }()
end

function Ark.Query(
  w::Ark.World,
  ::QueryData{R_Tuple,W_Tuple,WI_Tuple,WO_Tuple,O_Tuple},
) where {
  R_Tuple<:Tuple,
  W_Tuple<:Tuple,
  WI_Tuple<:Tuple,
  WO_Tuple<:Tuple,
  O_Tuple<:Tuple,
}
  component_types = map(O_Tuple.parameters) do T
    T <: Const ? Ark.Const{T.parameters[1]} : T
  end
  return Ark.Query(
    w,
    Tuple(component_types);
    with=Tuple(WI_Tuple.parameters),
    without=Tuple(WO_Tuple.parameters),
  )
end

reads(::QueryData{R,W,WI,WO,O}) where {R,W,WI,WO,O} = R
writes(::QueryData{R,W,WI,WO,O}) where {R,W,WI,WO,O} = W

reads(::Type{QueryData{R,W,WI,WO,O}}) where {R,W,WI,WO,O} = R.parameters
writes(::Type{QueryData{R,W,WI,WO,O}}) where {R,W,WI,WO,O} = W.parameters
