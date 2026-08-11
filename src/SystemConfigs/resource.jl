struct ResourceData{D, M} <: SystemConfig end

"""
    Res(T)

Describe read-only access to the resource of type `T` in an `Ark.World`.
The resource is passed as an argument to the system or condition.
"""
Res(::Type{T}) where {T} = ResourceData{T, false}()

"""
    ResMut(T)

Describe mutable access to the resource of type `T` in an `Ark.World`.
Systems that read or write the same resource are ordered safely.
"""
ResMut(::Type{T}) where {T} = ResourceData{T, true}()

reads(::ResourceData{T, false}) where {T} = (T,)

writes(::ResourceData{T, false}) where {T} = ()
writes(::ResourceData{T, true}) where {T} = (T,)


reads(::Type{ResourceData{D, false}}) where {D} = (D,)
reads(::Type{ResourceData{D, true}}) where {D} = ()

writes(::Type{ResourceData{D, false}}) where {D} = ()
writes(::Type{ResourceData{D, true}}) where {D} = (D,)
