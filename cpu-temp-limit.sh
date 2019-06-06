#!/bin/bash

# WARNING: THIS CODE IS CRAZY,
#           * RUN AT YOUR OWN RISK,
#           * READ AT YOUR OWN RISK.

# License:
# BSD 3-Clause License
# 
# Copyright (c) 2019, Jakub Svoboda
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
MAX_FREQ=4200000

# * the amount of seconds between runs, and the factor changes are multiplied by to account for the sleep length
# * the more often it runs, the more resources it consumes
# * the less often it runs, the less peaks it handless gracefully
SLEEP_AND_SPEEDUP=7

# * when the change is below this amount of percent, do nothing
# * sometimes the temperature is 1 percent above the target and it needlessly drifts towards the minimum frequency
HYSTERESIS_PERCENT=4


# Assuming hyperthreading and that the physical cores correspond to the logical cores {0,1}, {2,3}, ...
NUM_CPUS="$( grep -c -E '^processor' /proc/cpuinfo )"

if (( NUM_CPUS < 4 )) ; then
    echo "ERROR - less than 4 logical CPUs detected"
    exit 3
fi


NO_CGROUPS=0
NO_PSTATE=0

cgdelete_cpuset() {
    if (( NO_CGROUPS == 0 )) ; then
        cgdelete -g cpuset,memory:/temp_limiter_cpu_a ;
        cgdelete -g cpuset,memory:/temp_limiter_cpu_b ;
        cgdelete -g cpuset,memory:/temp_limiter_cpu_c ;
        cgdelete -g cpuset,memory:/temp_limiter_cpu_d ;
        cgdelete -g cpuset,memory:/temp_limiter_cpu_e ;
        cgdelete -g cpuset,memory:/temp_limiter_cpu_r ;
    fi
}

trap_exit() {
    cgdelete_cpuset
    cgdelete_cpuset  # shotgun: sometimes some cgroups stick after the first call
    if (( NO_PSTATE == 0 )) ; then
        # balance_performance is the default, but it results in quick overheating sometimes, which is why it is tweaked while the script is running, and reverted when it exits
        echo balance_power | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
        echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    fi
    exit 0
}

higher_time_lmtd_temp_target_mc=-1
higher_time_lmtd_temp_time_quota=-1
higher_time_lmtd_cnt=-1
higher_time_lmtd_reset_cnt=-1

print_usage() {
    echo "usage: ./$0 -t 59 [-r 69 5] [-n] [-p]"
    echo "    where 59 is the target temperature (degrees celsius)"
    echo "    -r 69 5 - allow temperature to rise up to 69 for up to 5 minutes per hour"
    echo "    -n - do not create cgroups"
    echo "    -p - do not require intel pstate"
    echo " "
    echo "The maximum frequency settings stay after the script is killed, but are lost after reboot."
}

while (( $# >= 1 )) ; do
    case "$1" in
        "-h" | "--help" )
            print_usage
            exit 0
            ;;
        "-n" )
            NO_CGROUPS=1
            echo "no cgroups"
            shift
            ;;
        "-p" )
            NO_PSTATE=1
            echo "no pstate requirement - only cpu frequency will be tweaked"
            shift
            ;;
        "-r" )
            higher_time_lmtd_temp_target_mc="$(( "$2" * 1000 ))"
            higher_time_lmtd_temp_time_quota="$3"
            echo "allowing temp $2 for up to $3 min per hour"
            shift 3
            ;;
        "-t" )
            # * no floating point arithmetic in bash
            temp_target_millicelsius="$(( "$2" * 1000 ))"
            shift 2
            ;;
        * )
            echo "ERROR: bad argument: $1"
            exit 6
            ;;
    esac
done

if (( temp_target_millicelsius < 35000 || temp_target_millicelsius > 90000 )) ; then
    echo "ERROR - temperature target outside of range 35-90"
    print_usage
    exit 2
fi

if (( NO_PSTATE == 0 )) ; then
    if [[ "$( cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver )" != "intel_pstate" || "$( cat /sys/devices/system/cpu/intel_pstate/status )" != "active" ]] ; then
        # The script modifies driver-specific scaling governor settings based on the temperature (/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference and /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor). These settings work very differently with passive intel pstate, or with cpufreq or other drivers.
        echo "ERROR - intel_pstate in active mode is not the scaling driver"
        print_usage
        exit 4
    fi
fi

trap 'trap_exit' SIGINT

cgdelete_cpuset

if (( NO_CGROUPS == 0 )) ; then
    # Randomizing the assignment of the physical cores to the groups of processes, so that I burn out the cpu evenly :-/
    # It may or may not be an issue, I don't know. [dons a tinfoil hat]
    # References:
    # * http://mitros.org/p/projects/silence/revamp/hotelectron/hotelectron.html
    # * https://yarchive.net/comp/linux/cpu_reliability.html
    # * https://electronics.stackexchange.com/questions/90648/electromigration-are-computers-nowadays-less-durable
    # * https://www.reddit.com/r/thinkpad/comments/4epc5h/intel_posts_warning_for_all_skylake_laptops/

    topology="$( cat /proc/cpuinfo | awk '
    BEGIN { firstcore=-1 ; hyperthreading=0 ; firstcores=-1 ; }
    /processor/ { proc=$3 } 
    /cpu cores/ { if ( firstcores == -1 ) { firstcores=$4 } }
    /core id/ { 
        if ( firstcore == -1 ) {
            firstcore=$4 ; firstproc=proc ; hyperthreading++;
        } else { 
            if ( firstcore == $4 ) {
                hyperthreading++;
                if ( proc == firstproc + 1 ) { 
                    print "A" ; 
                } else if ( proc == firstproc + firstcores ) {
                    print "B" ; 
                } else {
                    print "C" ; 
                }
                if (hyperthreading > 2) {
                    print "hyperthreading error - more than 2 hyperthreads" ; 
                }
            }
        }
    }
    ' )"

    hyperthreading="$( cat /proc/cpuinfo | awk '
    BEGIN { firstcore=-1 ; hyperthreading=0 ; }
    /core id/ { 
        if ( firstcore == -1 ) {
            firstcore=$4;
        } else { 
            if ( firstcore == $4 ) {
                hyperthreading++;
            }
        }
    }
    END {
        print hyperthreading;
    }
    ' )"

    echo "$topology"
    echo "$hyperthreading"
    if [[ "$hyperthreading" == "0" ]] ; then
        RANDOM_CORE=$(( RANDOM % NUM_CPUS ))  # at which core to start assigning
        echo "$RANDOM_CORE"
        for (( i=0; i<NUM_CPUS; i++ )) ; do
            # so use "cpu${RND_CORE[0]}" instead of "cpu0" in /sys/devices/system/cpu/
            RND_CORE[$i]="$(( ( RANDOM_CORE + i ) % NUM_CPUS ))"
        done
        declare -p RND_CORE
    else
        if [[ "$topology" == "A" ]] ; then
            RANDOM_CORE=$(( 2 * ( RANDOM % ( NUM_CPUS / 2 ) ) ))  # at which logical core to start assigning, always picking the first logical core of a physical core (the logical cores / physical core correspondence is {0,1}, {2,3}, {4,5}, {6,7}
            echo "$RANDOM_CORE"
            for (( i=0; i<NUM_CPUS; i++ )) ; do
                # so use "cpu${RND_CORE[0]}" instead of "cpu0" in /sys/devices/system/cpu/
                RND_CORE[$i]="$(( ( RANDOM_CORE + i ) % NUM_CPUS ))"
            done
            declare -p RND_CORE
        elif [[ "$topology" == "B" ]] ; then
            RANDOM_CORE=$(( RANDOM % ( NUM_CPUS / 2 ) ))  # at which logical core to start assigning, always picking the first logical core of a physical core (the logical cores / physical core correspondence is {0,4}, {1,5}, {2,6}, {3,7}
            echo "$RANDOM_CORE"
            for (( i=0; i < ( NUM_CPUS / 2); i++ )) ; do
                # so use "cpu${RND_CORE[0]}" instead of "cpu0" in /sys/devices/system/cpu/
                RND_CORE["$(( i * 2 ))"]="$(( ( RANDOM_CORE + i ) % ( NUM_CPUS / 2 ) ))"
                RND_CORE["$(( i * 2 + 1 ))"]="$(( 4 + ( RANDOM_CORE + i ) % ( NUM_CPUS / 2 ) ))"
            done
            declare -p RND_CORE
        else
            echo "ERROR - unknown CPU topology"
            exit 5
        fi
        # now, the logical cores of the same physical core belong to neighboring RND_CORE indexes
    fi
fi

freqincrcnt=0  # how many times the while loop has run after the last cpu frequency doubling / opportunistic frequency increase
lastcgroupscnt="$(( 235 / SLEEP_AND_SPEEDUP ))" # how many times the while loop has run after the last pid cpu pinning
freqcnt=100  # counter for reading current cpu frequency just once in a while
last_governor_setting=-1
new_max_freq_khz="$( cat /sys/devices/system/cpu/*/cpufreq/scaling_max_freq  | sort -n | tail -n1 )"  # for the first loop iteration
cgroups_created=0

relevant_sensors=()
for t in /sys/class/thermal/thermal_zone*/type ; do
    if [[ "iwlwifi" != "$( cat "$t" )" ]] ; then
        echo "adding sensor $(dirname "$t"): $( cat "$(dirname "$t")"/temp )  $( cat "$(dirname "$t")"/type )  "
        relevant_sensors+=( "$(dirname "$t")/temp" )
    fi ;
done

while true ; do
    # temp_millicelsius="$( cat /sys/class/thermal/thermal_zone*/temp | sort | tail -n 1 )"  ## iwlwifi reports irrelevant high temperatures; it would make the script work much worse
    temp_millicelsius="$( cat "${relevant_sensors[@]}" | sort | tail -n 1 )"
    max_freq_khz="${new_max_freq_khz}"
    echo "temp = $temp_millicelsius"
    (( freqcnt++ ))
    if (( freqcnt > ( 55 / SLEEP_AND_SPEEDUP ) )) ; then
        # this is expensive
        freq_khz="$( cat /sys/devices/system/cpu/*/cpufreq/scaling_cur_freq  | sort -n | tail -n1 )"
        echo "temp = $temp_millicelsius ; freq = $freq_khz"
        freqcnt=0
    fi
    echo "    max freq = $max_freq_khz"
    temp_under_target="$(( temp_target_millicelsius - temp_millicelsius ))"
    temp_under_target_relative_percent="$(( temp_under_target * 100 / temp_target_millicelsius ))"
    if (( higher_time_lmtd_temp_target_mc > temp_target_millicelsius )) ; then  # raised limit has been set
        if (( temp_under_target_relative_percent + HYSTERESIS_PERCENT < 0 )) ; then  # temp over normal limit
            if (( ( higher_time_lmtd_cnt * SLEEP_AND_SPEEDUP / 60 < higher_time_lmtd_temp_time_quota ) )) ; then  # raised temp quota left
                echo "    allowing higher temperature limit; $(( higher_time_lmtd_cnt * SLEEP_AND_SPEEDUP / 60 )) mins used so far"
                temp_under_target="$(( higher_time_lmtd_temp_target_mc - temp_millicelsius ))"
                temp_under_target_relative_percent="$(( temp_under_target * 100 / higher_time_lmtd_temp_target_mc ))"
                (( higher_time_lmtd_cnt++ ))
            else
                echo "    higher temperature limit used up; $(( ( 3600 - higher_time_lmtd_reset_cnt * SLEEP_AND_SPEEDUP ) / 60 )) mins until reset"
            fi
        fi

        # the reset counter is independent - it just resets the quota every hour
        (( higher_time_lmtd_reset_cnt++ ))
        if (( ( higher_time_lmtd_reset_cnt * SLEEP_AND_SPEEDUP ) > 3600 )) ; then
            higher_time_lmtd_cnt=-1
            higher_time_lmtd_reset_cnt=-1
        fi
    fi

    echo "    temp_under_target_relative_percent = $temp_under_target_relative_percent"

    # without the "/ 2", it would jump too much
    max_freq_khz_change="$(( ( max_freq_khz * temp_under_target_relative_percent * SLEEP_AND_SPEEDUP / 2 ) / 100  ))"
    if (( max_freq_khz_change < 0 )) ; then
        # however, when the cpu is overheating, drop the frequency rapidly
        max_freq_khz_change="$(( 3 * max_freq_khz_change ))"
    fi

    temp_under_target_relative_percent_absolute="${temp_under_target_relative_percent#-}"

    freq_incr=0
    if (( ( max_freq_khz < MAX_FREQ ) && ( temp_under_target_relative_percent_absolute <= HYSTERESIS_PERCENT ) )) ; then
        freqincrcnt="$(( freqincrcnt + 1 ))"
        # Once per ~40 seconds, if the frequency is (probably) approximately constant and the temperature around the target, try to increase the CPU frequency to get it out of the local optimum.
        # The reasoning is that sometimes and for some workloads, the CPU produces the same amount of heat no matter the frequency. And having a higher frequency is good for general usability. If it works out, good. If the CPU heats up, the script will lower the frequency again in the next cycle.
        if (( ( freqincrcnt > ( 40 / SLEEP_AND_SPEEDUP ) ) )) ; then
            freqincrcnt=0
            freq_incr=1
            echo "    trying to increase the current frequency to see what it does"
        fi
    fi

    if (( (temp_under_target_relative_percent_absolute >= HYSTERESIS_PERCENT) || (freq_incr == 1) )) ; then
        new_max_freq_khz="$(( ( freq_incr * MIN_FREQ ) + max_freq_khz + max_freq_khz_change ))"
        echo "    max_freq_khz_change=$max_freq_khz_change"
        echo "    new_max_freq_khz=$new_max_freq_khz"
        if (( new_max_freq_khz > MAX_FREQ )) ; then
            new_max_freq_khz="${MAX_FREQ}"
        fi
        if (( new_max_freq_khz < MIN_FREQ )) ; then
            new_max_freq_khz="${MIN_FREQ}"
        fi
        if (( max_freq_khz != new_max_freq_khz )) ; then
            echo "$new_max_freq_khz" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq
        fi
    else
        echo "    max_freq_khz_change=$max_freq_khz_change below hysteresis threshold"
    fi

    if (( NO_PSTATE == 0 )) ; then
        if (( temp_under_target_relative_percent < -8 )) ; then
            if (( last_governor_setting != 1 )) ; then
                echo power | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
                echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
                last_governor_setting=1
            fi
        elif (( temp_under_target_relative_percent < 5)) ; then
            if (( last_governor_setting != 2 )) ; then
                echo balance_power | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
                echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
                last_governor_setting=2
            fi
        else
            if (( last_governor_setting != 3 )) ; then
                echo balance_performance | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
                echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
                last_governor_setting=3
            fi
        fi
    fi

    if (( NO_CGROUPS == 0 )) ; then
        lastcgroupscnt="$(( lastcgroupscnt + 1 ))"
        if (( ((lastcgroupscnt * SLEEP_AND_SPEEDUP) > 245) || ( ((lastcgroupscnt * SLEEP_AND_SPEEDUP) > 25) && (temp_under_target_relative_percent < -20) ) || ( ((lastcgroupscnt * SLEEP_AND_SPEEDUP) > 125) && (temp_under_target_relative_percent < -7) ) )) ; then
            # run when one of these happens:
            # * once per ~245 secs
            # * if the temperature is more than 20% higher than the target, but at most once per ~25 secs
            # * if the temperature is more than 7% higher than the target, but at most once per ~125 secs

            # re-set task cpu affinity once in a while
            lastcgroupscnt=0

            echo "    re-setting cpu affinity for all processes"

            all_pids="$( pgrep -f -w '.' ; )"
            root_pids="$( pgrep -f -w -U 0 '.' ; )"

            # untouchable: Ignore everything GNOME-related, it seems to not like being assigned to the cgroups. Ignore important processes (terminals, vim). Ignore processes that don't like being restricted.
            group_u_pids="$( pgrep -f -w '/usr/libexec/gnome-terminal-server' ; pgrep -f -w '/usr/bin/gnome-shell' ; pgrep -f -w '/usr/bin/Xwayland' ; pgrep -f -w '/usr/bin/pulseaudio' ; pgrep -f -w '/usr/bin/nautilus' ; pgrep -f -w 'xfce4-terminal' ; pgrep -f -w 'gnome-terminal' ; pgrep -f -w 'xterm'  ; pgrep -f -w 'gnome'  ; pgrep -f -w 'gdm'; pgrep -w 'gvim' ; pgrep -w 'vim' ; pgrep -w 'rsync' ; )"

            # Browser: I want the (non-bluejeans) browser and music player to be separated from some other groups.
            group_a_pids="$( pgrep -f -w '/usr/bin/firefox' ; pgrep -f -w '/usr/lib64/firefox' ; pgrep -f -w '/usr/lib64/chromium' ; pgrep -f -w '/usr/bin/chromium' ; pgrep -f -w 'clementine' ; pgrep -f -w 'spotify' ; )"
            group_a_cores="${RND_CORE[0]},${RND_CORE[1]}"
            echo "        [ffox] group_a_cores=$group_a_cores"

            # TODO place stuff here - your optional memory hog
            group_b_pids="$( { echo "TODOTODOTODOTODO-replace-me-with-the-sth-like-the-pgreps-you-see-above" ; } | grep -vFx -f <( echo "${group_u_pids}" ; ) ; )"
            if (( NUM_CPUS < 8 )) ; then
                group_b_cores="${RND_CORE[2]}"
            else
                group_b_cores="${RND_CORE[2]},${RND_CORE[3]}"
            fi
            echo "        [TODO] group_b_cores=$group_b_cores"

            # spideroak etc: These are performance hogs that are not that important
            group_c_pids="$( pgrep -f -w '/usr/libexec/tracker-miner-fs' ; pgrep -f -w '/usr/libexec/tracker-store' ; pgrep -f -w 'SpiderOak'  ; pgrep -f -w 'duperemove' ; pgrep -w 'par2create' ; pgrep -w 'par2verify' ;   )"
            if (( NUM_CPUS < 8 )) ; then
                group_c_cores="${RND_CORE[2]}"
            else
                group_c_cores="${RND_CORE[2]},${RND_CORE[3]}"
            fi
            echo "        [spdr] group_c_cores=$group_c_cores"

            # chrome: this one hosts bluejeans (webrt) and it wants to eat all 8 cores on my computer sometimes :-( # TODO tweak based on your particular usecase!
            group_d_pids="$( pgrep -f -w '/opt/google/chrome' ; )"
            if (( NUM_CPUS < 8 )) ; then
                group_d_cores="${RND_CORE[2]},${RND_CORE[3]}"
            else
                group_d_cores="${RND_CORE[2]},${RND_CORE[3]},${RND_CORE[4]},${RND_CORE[5]}"
            fi
            echo "        [chrm] group_d_cores=$group_d_cores"

            # Work-related stuff
            group_e_pids="$( { pgrep -f -w 'prodsec' ; pgrep -f -w 'insights' ; pgrep -f -w 'pycharm' ; pgrep -f -w 'java' ; } | grep -vFx -f <( echo "${group_u_pids}" ; ) ; )"
            if (( NUM_CPUS < 8 )) ; then
                group_e_cores="$( for (( i=1; i<NUM_CPUS; i++ )) ; do echo -n "${RND_CORE[$i]}" ; if (( i < (NUM_CPUS - 1) )) ; then echo -n "," ; fi ; done )"
            else
                group_e_cores="$( for (( i=2; i<NUM_CPUS; i++ )) ; do echo -n "${RND_CORE[$i]}" ; if (( i < (NUM_CPUS - 1) )) ; then echo -n "," ; fi ; done )"
            fi
            echo "        [work] group_e_cores=$group_e_cores"

            # The rest of the processes (non-root only)
            # Ignore the remaining root processes so that the system doesn't grind into a halt if group r is overloaded.
            rest_of_pids="$( echo "${all_pids}" | grep -vFx -f <( echo "${group_u_pids}" ; echo "${group_a_pids}" ; echo "${group_b_pids}" ; echo "${group_c_pids}" ; echo "${group_d_pids}" ; echo "${group_e_pids}" ; echo "${root_pids}" ) ; )" 
            if (( NUM_CPUS < 8 )) ; then
                group_r_cores="$( for (( i=2; i<NUM_CPUS; i++ )) ; do echo -n "${RND_CORE[$i]}" ; if (( i < (NUM_CPUS - 1) )) ; then echo -n "," ; fi ; done )"
            else
                group_r_cores="$( for (( i=4; i<NUM_CPUS; i++ )) ; do echo -n "${RND_CORE[$i]}" ; if (( i < (NUM_CPUS - 1) )) ; then echo -n "," ; fi ; done )"
            fi
            echo "        [rest] group_r_cores=$group_r_cores"

            if (( cgroups_created == 0 )) ; then
                cgcreate -g cpuset,memory:/temp_limiter_cpu_a ; cgset -r cpuset.cpus="${group_a_cores}" temp_limiter_cpu_a ; cgset -r cpuset.mems=0 temp_limiter_cpu_a
                cgcreate -g cpuset,memory:/temp_limiter_cpu_b ; cgset -r cpuset.cpus="${group_b_cores}" temp_limiter_cpu_b ; cgset -r cpuset.mems=0 temp_limiter_cpu_b
                cgcreate -g cpuset,memory:/temp_limiter_cpu_c ; cgset -r cpuset.cpus="${group_c_cores}" temp_limiter_cpu_c ; cgset -r cpuset.mems=0 temp_limiter_cpu_c
                cgcreate -g cpuset,memory:/temp_limiter_cpu_d ; cgset -r cpuset.cpus="${group_d_cores}" temp_limiter_cpu_d ; cgset -r cpuset.mems=0 temp_limiter_cpu_d
                cgcreate -g cpuset,memory:/temp_limiter_cpu_e ; cgset -r cpuset.cpus="${group_e_cores}" temp_limiter_cpu_e ; cgset -r cpuset.mems=0 temp_limiter_cpu_e
                cgcreate -g cpuset,memory:/temp_limiter_cpu_r ; cgset -r cpuset.cpus="${group_r_cores}" temp_limiter_cpu_r ; cgset -r cpuset.mems=0 temp_limiter_cpu_r

                # memory limits
                # inspired by https://github.com/Feh/nocache/blob/master/README - alternate approaches
                cgset -r memory.limit_in_bytes="$((6000*1024*1024))" temp_limiter_cpu_a  # ffox
                cgset -r memory.limit_in_bytes="$((3500*1024*1024))" temp_limiter_cpu_b  # TODO
                cgset -r memory.limit_in_bytes="$((3500*1024*1024))" temp_limiter_cpu_c  # spdr
                cgset -r memory.limit_in_bytes="$((4000*1024*1024))" temp_limiter_cpu_d  # chrm
                cgset -r memory.limit_in_bytes="$((9000*1024*1024))" temp_limiter_cpu_e  # work
                cgset -r memory.limit_in_bytes="$((5000*1024*1024))" temp_limiter_cpu_r  # rest
                cgroups_created=1
            fi

            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_a  ${group_a_pids} 2>/dev/null
            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_b  ${group_b_pids} 2>/dev/null
            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_c  ${group_c_pids} 2>/dev/null
            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_d  ${group_d_pids} 2>/dev/null
            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_e  ${group_e_pids} 2>/dev/null
            # shellcheck disable=SC2086
            cgclassify -g cpuset,memory:temp_limiter_cpu_r  ${rest_of_pids} 2>/dev/null

            echo "    done"

        fi
    fi


    sleep "$SLEEP_AND_SPEEDUP"
done


# to profile this script:
#PS4='+ $( cp /tmp/bashprofiling /tmp/bashprofiling2 ; date "+%s.%N" > /tmp/bashprofiling ; cat /tmp/bashprofiling /tmp/bashprofiling2 | awk '"'"'{ if ( NR == 2) { printf "%s ", (x-$1) } else {x=$1} }'"'"'  ; echo " ($LINENO) ")'
# bash -x script 47 &>/tmp/profil
# cat /tmp/profil | sed -r 's/^\++ //' | grep -E '^[0-9]+\.[0-9]+ +\(' | sort -n | less
# 

