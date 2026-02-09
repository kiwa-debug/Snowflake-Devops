{#
  Staging Model: stg_bookings
  Cleans and casts raw VARCHAR data into proper types.
  Date format from source CSVs: DD/MM/YY
  Upstream: source('raw', 'booking_raw')
#}

with

source_data as (
    select * from {{ source('raw', 'booking_raw') }}
),

cleaned as (
    select
        -- Primary Key
        trim(booking_id)                                    as booking_id,

        -- Foreign Keys
        trim(listing_id)                                    as listing_id,
        trim(host_id)                                       as host_id,
        trim(guest_id)                                      as guest_id,

        -- Date Fields (source format: DD/MM/YY)
        try_to_date(trim(check_in_date), 'DD/MM/YY')       as check_in_date,
        try_to_date(trim(check_out_date), 'DD/MM/YY')      as check_out_date,
        try_to_date(trim(created_at), 'DD/MM/YY')          as created_at,

        -- Nights booked (calculated)
        case
            when try_to_date(trim(check_in_date), 'DD/MM/YY') is not null
                 and try_to_date(trim(check_out_date), 'DD/MM/YY') is not null
            then datediff('day',
                          try_to_date(trim(check_in_date), 'DD/MM/YY'),
                          try_to_date(trim(check_out_date), 'DD/MM/YY'))
            else null
        end                                                 as nights_booked,

        -- Financial Fields
        try_to_decimal(trim(total_price), 12, 2)            as total_price,

        -- Currency
        upper(trim(currency))                               as currency,

        -- Status Fields (lowercase for consistency)
        lower(trim(booking_status))                         as booking_status,

        -- Data Quality Flag
        case
            when trim(booking_id) is null or trim(booking_id) = ''         then true
            when try_to_date(trim(check_in_date), 'DD/MM/YY') is null     then true
            when try_to_date(trim(check_out_date), 'DD/MM/YY') is null    then true
            when try_to_date(trim(check_out_date), 'DD/MM/YY')
                 < try_to_date(trim(check_in_date), 'DD/MM/YY')           then true
            when try_to_decimal(trim(total_price), 12, 2) < 0             then true
            else false
        end                                                 as _is_invalid_record

    from source_data
),

final as (
    select *
    from cleaned
    where booking_id is not null
)

select * from final
