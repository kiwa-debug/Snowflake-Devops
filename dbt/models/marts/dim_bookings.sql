{#
  Dimension Model: dim_bookings
  Analytics-ready table with enriched booking data.
  Business logic: stay categories, lead time, price metrics, status flags.
  Upstream: ref('stg_bookings')
#}

{{
  config(
    materialized = 'table',
    unique_key = 'booking_id',
    tags = ['dimension', 'daily']
  )
}}

with

staged_bookings as (
    select * from {{ ref('stg_bookings') }}
    where _is_invalid_record = false
),

enriched as (
    select
        -- Surrogate Key
        {{ dbt_utils.generate_surrogate_key(['booking_id']) }} as booking_key,

        -- Natural Key
        booking_id,

        -- Foreign Keys
        listing_id,
        host_id,
        guest_id,

        -- Dates
        check_in_date,
        check_out_date,
        created_at,
        nights_booked,

        -- Financial Metrics
        total_price,
        currency,

        -- Price per night (calculated from total / nights)
        case
            when nights_booked > 0
            then round(total_price / nights_booked, 2)
            else null
        end as price_per_night,

        -- Revenue (only for completed/confirmed bookings)
        case
            when booking_status in ('completed', 'confirmed')
            then total_price
            else 0
        end as realized_revenue,

        -- Booking Status
        booking_status,

        -- User-friendly status display
        case booking_status
            when 'confirmed'  then 'Confirmed'
            when 'pending'    then 'Pending Confirmation'
            when 'cancelled'  then 'Cancelled'
            when 'completed'  then 'Completed'
            else 'Unknown'
        end as booking_status_display,

        -- Status boolean flags
        booking_status = 'confirmed' as is_confirmed,
        booking_status = 'pending' as is_pending,
        booking_status = 'cancelled' as is_cancelled,
        booking_status = 'completed' as is_completed,
        booking_status in ('confirmed', 'completed') as is_successful,

        -- Stay Categorization
        case
            when nights_booked is null    then 'Unknown'
            when nights_booked <= 2       then 'Weekend'
            when nights_booked <= 7       then 'Week'
            when nights_booked <= 30      then 'Monthly'
            else 'Long-term'
        end as stay_category,

        case
            when nights_booked is null    then 0
            when nights_booked <= 2       then 1
            when nights_booked <= 7       then 2
            when nights_booked <= 30      then 3
            else 4
        end as stay_category_order,

        -- Lead Time (days between booking creation and check-in)
        case
            when created_at is not null and check_in_date is not null
            then datediff('day', created_at, check_in_date)
            else null
        end as lead_time_days,

        case
            when created_at is null or check_in_date is null then 'Unknown'
            when datediff('day', created_at, check_in_date) < 0 then 'Historical'
            when datediff('day', created_at, check_in_date) <= 1 then 'Same Day'
            when datediff('day', created_at, check_in_date) <= 7 then 'Last Minute (1-7 days)'
            when datediff('day', created_at, check_in_date) <= 30 then 'Short Notice (8-30 days)'
            when datediff('day', created_at, check_in_date) <= 90 then 'Advance (31-90 days)'
            else 'Far Advance (90+ days)'
        end as lead_time_category,

        -- Time Dimensions (check-in based)
        date_trunc('week', check_in_date) as check_in_week,
        date_trunc('month', check_in_date) as check_in_month,
        date_trunc('quarter', check_in_date) as check_in_quarter,
        year(check_in_date) as check_in_year,
        month(check_in_date) as check_in_month_num,
        dayofweek(check_in_date) as check_in_day_of_week,
        dayname(check_in_date) as check_in_day_name,
        dayofweek(check_in_date) in (0, 6) as is_weekend_checkin,

        -- Metadata
        current_timestamp() as _dbt_updated_at

    from staged_bookings
),

final as (
    select * from enriched
)

select * from final
