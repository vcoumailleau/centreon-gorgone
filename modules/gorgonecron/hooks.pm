# 
# Copyright 2019 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package modules::gorgonecron::hooks;

use warnings;
use strict;
use centreon::script::gorgonecore;
use modules::gorgonecron::class;

my $config_core;
my $config;
my $module_shortname = 'cron';
my $module_id = 'gorgonecron';
my $events = [
    { event => 'CRONREADY' },
    { event => 'RELOADCRON', uri => '/reload', method => 'POST' },
    { event => 'LISTCRON', uri => '/list', method => 'GET' },
];
my $cron = {};
my $stop = 0;

sub register {
    my (%options) = @_;
    
    $config = $options{config};
    $config_core = $options{config_core};
    return ($events, $module_shortname , $module_id);
}

sub init {
    my (%options) = @_;

    create_child(logger => $options{logger});
}

sub routing {
    my (%options) = @_;

    my $data;
    eval {
        $data = JSON->new->utf8->decode($options{data});
    };
    if ($@) {
        $options{logger}->writeLogError("Cannot decode json data: $@");
        centreon::gorgone::common::add_history(
            dbh => $options{dbh},
            code => 10, token => $options{token},
            data => { message => 'gorgonecron: cannot decode json' },
            json_encode => 1
        );
        return undef;
    }
    
    if ($options{action} eq 'CRONREADY') {
        $cron->{ready} = 1;
        return undef;
    }
    
    if (centreon::script::gorgonecore::waiting_ready(ready => \$cron->{ready}) == 0) {
        centreon::gorgone::common::add_history(
            dbh => $options{dbh},
            code => 10, token => $options{token},
            data => { message => 'gorgonecron: still no ready' },
            json_encode => 1
        );
        return undef;
    }
    
    centreon::gorgone::common::zmq_send_message(
        socket => $options{socket}, identity => 'gorgonecron',
        action => $options{action}, data => $options{data}, token => $options{token},
    );
}

sub gently {
    my (%options) = @_;

    $stop = 1;
    $options{logger}->writeLogInfo("gorgone-cron: Send TERM signal");
    if ($cron->{running} == 1) {
        CORE::kill('TERM', $cron->{pid});
    }
}

sub kill {
    my (%options) = @_;

    if ($cron->{running} == 1) {
        $options{logger}->writeLogInfo("gorgone-cron: Send KILL signal for pool");
        CORE::kill('KILL', $cron->{pid});
    }
}

sub kill_internal {
    my (%options) = @_;

}

sub check {
    my (%options) = @_;

    my $count = 0;
    foreach my $pid (keys %{$options{dead_childs}}) {
        # Not me
        next if ($cron->{pid} != $pid);
        
        $cron = {};
        delete $options{dead_childs}->{$pid};
        if ($stop == 0) {
            create_child(logger => $options{logger});
        }
    }
    
    $count++  if (defined($cron->{running}) && $cron->{running} == 1);
    
    return $count;
}

# Specific functions
sub create_child {
    my (%options) = @_;
    
    $options{logger}->writeLogInfo("Create gorgonecron process");
    my $child_pid = fork();
    if ($child_pid == 0) {
        $0 = 'gorgone-cron';
        my $module = modules::gorgonecron::class->new(
            logger => $options{logger},
            config_core => $config_core,
            config => $config,
        );
        $module->run();
        exit(0);
    }
    $options{logger}->writeLogInfo("PID $child_pid gorgonecron");
    $cron = { pid => $child_pid, ready => 0, running => 1 };
}

1;