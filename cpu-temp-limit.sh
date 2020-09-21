#!/bin/bash

# WARNING: THIS CODE IS CRAZY,
#           * RUN AT YOUR OWN RISK,
#           * READ AT YOUR OWN RISK.

# License:
# BSD 3-Clause License
# 
# Copyright (c) 2020, Jakub Svoboda
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
# 
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



# * this script adaptively sets the maximum cpu frequency based on the current temperature and the specified target maximum temperature

# * better than just setting max freq because it allows the maximum speedstep freq when the computer is under the target temperature

# * better than using the techniques from https://github.com/erpalma/lenovo-throttling-fix and https://github.com/BelBES/thinkpad_x1_carbon_6th_linux because there is no risk of crashes caused by undervolting or by writing to MSR and stuff (https://lwn.net/Articles/706637/)

# * better than https://github.com/intel/thermal_daemon in the aspect that it has no dependencies, works out of the box, uses only safe kernel apis (the sysfs interface), no low-level stuff, no risk of hang or crash; otherwise https://github.com/intel/thermal_daemon is immensely better, of course :)

# * worse than just letting the fans do their work, if you care about performance and don't care about temperature


# * CPU model-specific; this one is for i7-8650U
# * the kernel won't allow setting values outside of this rage, but it is more elegant to not even try
# * note that this script only sets the maximum frequency, so setting MIN_FREQ high here doesn't limit the cpu from going to a lower frequency when not under load
MIN_FREQ=700000  # the hardware minimum (400 MHz) is too slow for bluejeans; also the power consumption / performance ratio seems to be significantly worse below ~650 MHz, giving almost no power saving for noticeably less performance
MAX_FREQ_TURBO=4200000
MAX_FREQ_NOTURBO=1900000


SLEEP=7

USE_PSTATE=1
if [[ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)" != "intel_pstate" ]] ;
then
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
    USE_PSTATE=0
fi

RELEVANT_SENSORS=()
# iwlwifi reports irrelevant high temperatures; it would make the script work much worse
# TODO: adjust based on your particular system
for t in /sys/class/thermal/thermal_zone*/type ; do
    if [[ "iwlwifi" != "$( cat "$t" )" ]] ; then
        echo "adding sensor $(dirname "$t"): $( cat "$(dirname "$t")"/temp )  $( cat "$(dirname "$t")"/type )  "
        RELEVANT_SENSORS+=( "$(dirname "$t")/temp" )
    fi ;
done


print_usage() {
    echo "usage: ./$0 -t 59"
    echo "    where 59 is the target temperature (degrees celsius)"
    echo "    -t - valid values: 35-90"
    echo " "
    echo "The maximum frequency and governor settings stay modified after the script is killed, but are lost after reboot."
}

while (( $# >= 1 )) ; do
    case "$1" in
        "-h" | "--help" )
            print_usage
            exit 0
            ;;
        "-t" )
            # * no floating point arithmetic in bash
            TEMP_TARGET_MILLICELSIUS="$(( "$2" * 1000 ))"
            shift 2
            ;;
        * )
            echo "ERROR: bad argument: $1"
            exit 6
            ;;
    esac
done

if (( TEMP_TARGET_MILLICELSIUS < 35000 || TEMP_TARGET_MILLICELSIUS > 90000 )) ; then
    echo "ERROR - temperature target outside of range 35-90"
    print_usage
    exit 2
fi



_governor_last_1=""
_governor_last_2=""
set_governor_pstate() {
    if [[ "$_governor_last_1" != "$1" ]] ; then
        echo "$1" | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
        _governor_last_1="$1"
    fi

    if [[ "$_governor_last_2" != "$2" ]] ; then
        echo "$2" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        _governor_last_2="$2"
    fi
}

set_governor_cpufreq() {
    if [[ "$_governor_last_1" != "$1" ]] ; then
        echo "$1" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        _governor_last_1="$1"
    fi
}

hottest_sensor_path=""

select_hottest_sensor() {
    local hottest_path=""
    local hottest_value=0
    local val=0
    for sens_path in "${RELEVANT_SENSORS[@]}" ; do
        val="$( cat "$sens_path" )"

        if (( val > hottest_value )) ; then
            hottest_path="$sens_path"
            hottest_value="$val"
        fi
    done

    echo "    hottest_sensor_path=$hottest_path"
    hottest_sensor_path="$hottest_path"
}

temp_millicelsius=0
_temp_autoselect_cnt=0
_temp_autoselect_hottest=0
_TEMP_AUTOSELECT_END=30
read_temperature() {
    # Reading all sensors is expensive. Read all sensors if:
    # - the hottest one hasn't been selected yet
    # - randomly 10% of the time to have a chance to discover whether another sensor has become too hot
    if [[ -z "$hottest_sensor_path" ]] || (( RANDOM % 10 == 0 )) ; then
        echo "    reading temp from all sensors"
        temp_millicelsius="$( cat "${RELEVANT_SENSORS[@]}" | sort | tail -n 1 )"

        # Select the hottest sensor after some observation.
        if (( _temp_autoselect_cnt > _TEMP_AUTOSELECT_END )) ; then
            :
        elif (( _temp_autoselect_cnt == _TEMP_AUTOSELECT_END )) ; then
            if (( _temp_autoselect_hottest < temp_millicelsius )) ; then
                select_hottest_sensor
                _temp_autoselect_cnt="$(( _temp_autoselect_cnt + 1 ))"
            fi
        elif (( ++_temp_autoselect_cnt < _TEMP_AUTOSELECT_END )) ; then
            if (( _temp_autoselect_hottest < temp_millicelsius )) ; then
                _temp_autoselect_hottest="$temp_millicelsius"
            fi
        fi
    else
        temp_millicelsius="$( cat "$hottest_sensor_path" )"
    fi
}

MAX_FREQ_TURBO_LOWERED_1="$(( ( MAX_FREQ_NOTURBO + MAX_FREQ_TURBO ) / 2 ))"
MAX_FREQ_TURBO_LOWERED_2="$(( MAX_FREQ_TURBO - ( ( MAX_FREQ_TURBO - MAX_FREQ_NOTURBO ) / 3 ) ))"

new_max_freq_khz="$( cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq )"
while true ; do
    read_temperature
    max_freq_khz="$new_max_freq_khz"
    echo "temp = $temp_millicelsius"
    freq_khz="$( cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq )"
    echo "    freq = $freq_khz"
    under_target_percent="$(( ( TEMP_TARGET_MILLICELSIUS - temp_millicelsius ) * 100 / TEMP_TARGET_MILLICELSIUS ))"
    echo "    under_target_percent = $under_target_percent"
    if (( under_target_percent < -2 )) ; then
        select_hottest_sensor
    fi

    if (( ( max_freq_khz < MAX_FREQ_NOTURBO ) && ( RANDOM % 50 == 0 ) )) ; then
        # with a 2% probability, set the max allowed freq to the maximum - during certain loads the temperature stays the same no matter the frequency but the computation speed depends on the frequency, so this is a way out of such situations
        under_target_percent="10"
    fi

    if (( USE_PSTATE )) ; then
        if (( under_target_percent < -8 )) ; then
            set_governor_pstate power powersave
        elif (( under_target_percent < 5 )) ; then
            set_governor_pstate balance_power powersave
        else
            set_governor_pstate balance_performance powersave
        fi
    else
        if (( under_target_percent < -8 )) ; then
            set_governor_cpufreq powersave
        else
            set_governor_cpufreq schedutil
        fi
    fi

    # The CPU heats up disproportionately faster in the Turbo Boost frequency range than in the non-Turbo Boost range.
    # As a result, the script might limit the frequency too much, resulting in laggy performance.
    if (( under_target_percent < 11 )) ; then
        MAX_FREQ="$MAX_FREQ_NOTURBO"
    elif (( under_target_percent < 16 )) ; then
        MAX_FREQ="$MAX_FREQ_TURBO_LOWERED_1"
    elif (( under_target_percent < 21 )) ; then
        MAX_FREQ="$MAX_FREQ_TURBO_LOWERED_2"
    else
        MAX_FREQ="$MAX_FREQ_TURBO"
    fi

    # the ` / 2` makes the change smaller to avoid jumps in performance
    new_max_freq_khz="$(( max_freq_khz + ( ( SLEEP * max_freq_khz * under_target_percent ) / 100 / 2 ) ))"
    if (( new_max_freq_khz > MAX_FREQ )) ; then
        new_max_freq_khz="$MAX_FREQ"
    fi
    if (( new_max_freq_khz < MIN_FREQ )) ; then
        new_max_freq_khz="$MIN_FREQ"
    fi
    if (( max_freq_khz != new_max_freq_khz )) ; then
        echo "$new_max_freq_khz" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq
    fi

    sleep "$SLEEP"
done
