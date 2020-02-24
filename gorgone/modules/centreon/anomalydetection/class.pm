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

package gorgone::modules::centreon::anomalydetection::class;

use base qw(gorgone::class::module);

use strict;
use warnings;
use gorgone::standard::library;
use gorgone::class::sqlquery;
use gorgone::class::http::http;
use ZMQ::LibZMQ4;
use ZMQ::Constants qw(:all);
use JSON::XS;

my %handlers = (TERM => {}, HUP => {});
my ($connector);

sub new {
    my ($class, %options) = @_;

    $connector  = {};
    $connector->{internal_socket} = undef;
    $connector->{module_id} = $options{module_id};
    $connector->{logger} = $options{logger};
    $connector->{config} = $options{config};
    $connector->{config_core} = $options{config_core};
    $connector->{config_db_centreon} = $options{config_db_centreon};
    $connector->{config_db_centstorage} = $options{config_db_centstorage};
    $connector->{stop} = 0;

    $connector->{resync_time} = (defined($options{config}->{resync_time}) && $options{config}->{resync_time} =~ /(\d+)/) ? $1 : 600;
    $connector->{last_resync_time} = -1;
    $connector->{saas_token} = undef;
    $connector->{saas_url} = undef;
    $connector->{proxy_url} = undef; # format http://[username:password@]server:port
    $connector->{centreon_metrics} = {};
    $connector->{unregister_metrics_centreon} = {};

    bless $connector, $class;
    $connector->set_signal_handlers();
    return $connector;
}

sub set_signal_handlers {
    my $self = shift;

    $SIG{TERM} = \&class_handle_TERM;
    $handlers{TERM}->{$self} = sub { $self->handle_TERM() };
    $SIG{HUP} = \&class_handle_HUP;
    $handlers{HUP}->{$self} = sub { $self->handle_HUP() };
}

sub handle_HUP {
    my $self = shift;
    $self->{reload} = 0;
}

sub handle_TERM {
    my $self = shift;
    $self->{logger}->writeLogDebug("[anomalydetection] $$ Receiving order to stop...");
    $self->{stop} = 1;
}

sub class_handle_TERM {
    foreach (keys %{$handlers{TERM}}) {
        &{$handlers{TERM}->{$_}}();
    }
}

sub class_handle_HUP {
    foreach (keys %{$handlers{HUP}}) {
        &{$handlers{HUP}->{$_}}();
    }
}

sub http_check_error {
    my ($self, %options) = @_;

    if ($options{status} == 1) {
        $self->{logger}->writeLogError("[anomalydetection] -class- $options{endpoint} issue");
        return 1;
    }

    my $code = $self->{http}->get_code();
    if ($code !~ /$options{http_code_continue}/) {
        $self->{logger}->writeLogError("[anomalydetection] -class- $options{endpoint} issue - " . $self->{http}->get_message());
        return 1;
    }

    return 0;
}

sub saas_api_request {
    my ($self, %options) = @_;

    my ($status, $payload);
    if (defined($options{payload})) {
        ($status, $payload) = $self->json_encode(argument => $options{payload});
        return 1 if ($status == 1);
    }

    ($status, my $response) = $self->{http}->request(
        method => $options{method}, hostname => '',
        full_url => $self->{saas_url} . $options{endpoint},
        query_form_post => $payload,
        header => [
            'Accept-Type: application/json; charset=utf-8',
            'Content-Type: application/json; charset=utf-8',
            'x-api-key: ' . $self->{saas_token}
        ],
        proxyurl => $self->{proxy_url},
        curl_opt => ['CURLOPT_SSL_VERIFYPEER => 0']
    );
    return 1 if ($self->http_check_error(status => $status, endpoint => $options{endpoint}, http_code_continue => $options{http_code_continue}) == 1);

    ($status, my $result) = $self->json_decode(argument => $response);
    return 1 if ($status == 1);

    return (0, $result);
}

sub connection_informations {
    my ($self, %options) = @_;

    my ($status, $datas) = $self->{class_object_centreon}->custom_execute(
        request => "select `key`, `value` from options WHERE `key` IN ('saas_url', 'saas_token', 'proxy_url', 'proxy_port', 'proxy_user', 'proxy_password')",
        mode => 2
    );
    if ($status == -1) {
        $self->{logger}->writeLogError('[anomalydetection] -class- cannot get connection informations');
        return 1;
    }

    $self->{$_->[0]} = $_->[1] foreach (@$datas);

    if (!defined($self->{saas_url}) || $self->{saas_url} eq '') {
        $self->{logger}->writeLogError('[anomalydetection] -class- database: saas_url is not defined');
        return 1;
    }
    if (!defined($self->{saas_token}) || $self->{saas_token} eq '') {
        $self->{logger}->writeLogError('[anomalydetection] -class- database: saas_token is not defined');
        return 1;
    }

    if (defined($self->{proxy_url})) {
        if ($self->{proxy_url} eq '') {
            $self->{proxy_url} = undef;
            return 0;
        }

        $self->{proxy_url} = $self->{proxy_user} . ':' . $self->{proxy_password} . '@' . $self->{proxy_url}
            if (defined($self->{proxy_user}) && $self->{proxy_user} ne '' &&
                defined($self->{proxy_password}) && $self->{proxy_password} ne '');
        $self->{proxy_url} = $self->{proxy_url} . ':' . $self->{proxy_port}
            if (defined($self->{proxy_port}) && $self->{proxy_port} =~ /(\d+)/);
        $self->{proxy_url} = 'http://' . $self->{proxy_url};
    }

    return 0;
}

sub get_centreon_anomaly_metrics {
    my ($self, %options) = @_;

    my ($status, $datas) = $self->{class_object_centreon}->custom_execute(
        request => '
            SELECT mas.*, hsr.host_host_id as host_id
            FROM mod_anomaly_service mas, host_service_relation hsr
            WHERE mas.service_id = hsr.service_service_id
        ',
        keys => 'id',
        mode => 1
    );
    if ($status == -1) {
        $self->{logger}->writeLogError('[anomalydetection] -class- database: cannot get metrics from centreon');
        return 1;
    }

    $self->{centreon_metrics} = $datas;

    my $metric_ids = {};
    foreach (keys %{$self->{centreon_metrics}}) {
        if (!defined($self->{centreon_metrics}->{$_}->{saas_creation_date})) {
            $metric_ids->{ $self->{centreon_metrics}->{$_}->{metric_id} } = $_;
        }
    }

    if (scalar(keys %$metric_ids) > 0) {
        ($status, $datas) = $self->{class_object_centstorage}->custom_execute(
            request => 'SELECT `metric_id`, `metric_name` FROM metrics  WHERE metric_id IN (' . join(', ', keys %$metric_ids) . ')',
            mode => 2
        );
        if ($status == -1) {
            $self->{logger}->writeLogError('[anomalydetection] -class- database: cannot get metric name informations');
            return 2;
        }

        foreach (@$datas) {
            $self->{centreon_metrics}->{ $metric_ids->{ $_->[0] } }->{metric_name} = $_->[1];
        }
    }

    return 0;
}

sub save_centreon_previous_register {
    my ($self, %options) = @_;

    my ($query, $query_append) = ('', '');
    foreach (keys %{$self->{unregister_metrics_centreon}}) {
        $query .= $query_append . 
            'UPDATE mod_anomaly_service SET' .
            ' saas_model_id = ' . $self->{class_object_centreon}->quote(value => $self->{unregister_metrics_centreon}->{$_}->{saas_model_id}) . ',' .
            ' saas_metric_id = ' . $self->{class_object_centreon}->quote(value => $self->{unregister_metrics_centreon}->{$_}->{saas_metric_id}) . ',' .
            ' saas_creation_date = ' . $self->{unregister_metrics_centreon}->{$_}->{creation_date} .
            ' WHERE `id` = ' . $_;
        $query_append = ';';
    }
    if ($query ne '') {
        my $status = $self->{class_object_centreon}->transaction_query(request => $query);
        if ($status == -1) {
            $self->{logger}->writeLogError('[anomalydetection] -class- database: cannot save centreon previous register');
            return 1;
        }

        foreach (keys %{$self->{unregister_metrics_centreon}}) {
            $self->{centreon_metrics}->{$_}->{saas_creation_date} = $self->{unregister_metrics_centreon}->{$_}->{creation_date};
            $self->{centreon_metrics}->{$_}->{saas_model_id} = $self->{unregister_metrics_centreon}->{$_}->{saas_model_id};
            $self->{centreon_metrics}->{$_}->{saas_metric_id} = $self->{unregister_metrics_centreon}->{$_}->{saas_metric_id};
        }
    }

    $self->{unregister_metrics_centreon} = {};
    return 0;
}

sub saas_register_metrics {
    my ($self, %options) = @_;

    my $register_centreon_metrics = {};
    my ($query, $query_append) = ('', '');
    
    $self->{generate_metrics_lua} = 0;
    foreach (keys %{$self->{centreon_metrics}}) {
        # metric_name is set when we need to register it
        next if (!defined($self->{centreon_metrics}->{$_}->{metric_name}));
        next if ($self->{centreon_metrics}->{$_}->{saas_to_delete} == 1);

        my $payload = {
            metrics => [
                {
                    name => $self->{centreon_metrics}->{$_}->{metric_name},
                    labels => {
                        host_id => $self->{centreon_metrics}->{$_}->{host_id},
                        service_id => $self->{centreon_metrics}->{$_}->{service_id}
                    },
                    preprocessingOptions =>  {
                        bucketize => {
                            bucketizeFunction => 'mean',
                            period => 300
                        }
                    }
                }
            ],
            algorithm => {
                type => $self->{centreon_metrics}->{$_}->{ml_model_name},
                options => {
                    period => '30d'
                }
            }
        };

        my ($status, $result) = $self->saas_api_request(
            endpoint => '/machinelearning',
            method => 'POST',
            payload => $payload,
            http_code_continue => '^2'
        );
        return 1 if ($status);

        $self->{logger}->writeLogDebug(
            "[anomalydetection] -class- saas: metric '$self->{centreon_metrics}->{$_}->{host_id}/$self->{centreon_metrics}->{$_}->{service_id}/$self->{centreon_metrics}->{$_}->{metric_name}' registered"
        );

        # {"metrics": [{"name":"system_load1","labels":{"hostname":"srvi-monitoring"},"preprocessingOptions":{"bucketize":{"bucketizeFunction":"mean","period":300}},"id":"e255db55-008b-48cd-8dfe-34cf60babd01"}],"algorithm":{"type":"h2o","options":{"period":"180d"}},
        #  "id":"257fc68d-3248-4c92-92a1-43c0c63d5e5e"}

        $self->{generate_metrics_lua} = 1;
        $register_centreon_metrics->{$_} = {
            saas_creation_date => time(),
            saas_model_id => $result->{id},
            saas_metric_id => $result->{metrics}->[0]->{id}
        };

        $query .= $query_append . 
            'UPDATE mod_anomaly_service SET' .
            ' saas_model_id = ' . $self->{class_object_centreon}->quote(value => $register_centreon_metrics->{$_}->{saas_model_id}) . ',' .
            ' saas_metric_id = ' . $self->{class_object_centreon}->quote(value => $register_centreon_metrics->{$_}->{saas_metric_id}) . ',' .
            ' saas_creation_date = ' . $register_centreon_metrics->{$_}->{saas_creation_date} .
            ' WHERE `id` = ' . $_;
        $query_append = ';';
    }

    return 0 if ($query eq '');

    my $status = $self->{class_object_centreon}->transaction_query(request => $query);
    if ($status == -1) {
        $self->{unregister_metrics_centreon} = $register_centreon_metrics;
        $self->{logger}->writeLogError('[anomalydetection] -class- dabase: cannot update centreon register');
        return 1;
    }

    foreach (keys %$register_centreon_metrics) {
        $self->{centreon_metrics}->{$_}->{saas_creation_date} = $register_centreon_metrics->{$_}->{saas_creation_date};
        $self->{centreon_metrics}->{$_}->{saas_metric_id} = $register_centreon_metrics->{$_}->{saas_metric_id};
        $self->{centreon_metrics}->{$_}->{saas_model_id} = $register_centreon_metrics->{$_}->{saas_model_id};
    }

    return 0;
}

sub saas_delete_metrics {
    my ($self, %options) = @_;

    my $delete_ids = [];
    foreach (keys %{$self->{centreon_metrics}}) {
        next if ($self->{centreon_metrics}->{$_}->{saas_to_delete} == 0);

        if (defined($self->{centreon_metrics}->{$_}->{saas_model_id})) {
            my ($status, $result) = $self->saas_api_request(
                endpoint => '/machinelearning/' . $self->{centreon_metrics}->{$_}->{saas_model_id},
                method => 'DELETE',
                http_code_continue => '^(?:2|404)'
            );
            next if ($status);

            $self->{logger}->writeLogDebug(
                "[anomalydetection] -class- saas:: metric '$self->{centreon_metrics}->{$_}->{host_id}/$self->{centreon_metrics}->{$_}->{service_id}/$self->{centreon_metrics}->{$_}->{metric_name}' deleted"
            );

            next if (!defined($result->{message}) ||
                $result->{message} !~ /machine learning request id is not found/i);
        }

        push @$delete_ids, $_;
    }

    return 0 if (scalar(@$delete_ids) <= 0);

    my $status = $self->{class_object_centreon}->transaction_query(
        request => 'DELETE FROM mod_anomaly_service WHERE id IN (' . join(', ', @$delete_ids) . ')'
    );
    if ($status == -1) {
        $self->{logger}->writeLogError('[anomalydetection] -class- database: cannot delete centreon saas');
        return 1;
    }

    return 0;
}

sub action_adsync {
    my ($self, %options) = @_;

    $options{token} = $self->generate_token() if (!defined($options{token}));
    $self->send_log(code => gorgone::class::module::ACTION_BEGIN, token => $options{token}, data => { message => 'action adsync proceed' });

    if ($self->connection_informations()) {
        $self->send_log(code => gorgone::class::module::ACTION_FINISH_KO, token => $options{token}, data => { message => 'cannot get connection informations' });
        return 1;
    }

    if ($self->save_centreon_previous_register()) {
        $self->send_log(code => gorgone::class::module::ACTION_FINISH_KO, token => $options{token}, data => { message => 'cannot save previsous register' });
        return 1;
    }

    if ($self->get_centreon_anomaly_metrics()) {
        $self->send_log(code => gorgone::class::module::ACTION_FINISH_KO, token => $options{token}, data => { message => 'cannot get metrics from centreon' });
        return 1;
    }

    if ($self->saas_register_metrics()) {
        $self->send_log(code => gorgone::class::module::ACTION_FINISH_KO, token => $options{token}, data => { message => 'cannot get declare metrics in saas' });
        return 1;
    }

    if ($self->{generate_metrics_lua} == 1) {
        # need to generate a new file (TODO)
    }

    if ($self->saas_delete_metrics()) {
        $self->send_log(code => gorgone::class::module::ACTION_FINISH_KO, token => $options{token}, data => { message => 'cannot delete metrics in saas' });
        return 1;
    }

    $self->{logger}->writeLogDebug("[anomalydetection] Finish adsync");
    $self->send_log(code => $self->ACTION_FINISH_OK, token => $options{token}, data => { message => 'action adsync finished' });
    return 0;
}

sub event {
    while (1) {
        my $message = gorgone::standard::library::zmq_dealer_read_message(socket => $connector->{internal_socket});

        $connector->{logger}->writeLogDebug("[anomalydetection] Event: $message");
        if ($message =~ /^\[(.*?)\]/) {
            if ((my $method = $connector->can('action_' . lc($1)))) {
                $message =~ /^\[(.*?)\]\s+\[(.*?)\]\s+\[.*?\]\s+(.*)$/m;
                my ($action, $token) = ($1, $2);
                my $data = JSON::XS->new->utf8->decode($3);
                $method->($connector, token => $token, data => $data);
            }
        }

        last unless (gorgone::standard::library::zmq_still_read(socket => $connector->{internal_socket}));
    }
}

sub run {
    my ($self, %options) = @_;

    $self->{db_centreon} = gorgone::class::db->new(
        dsn => $self->{config_db_centreon}->{dsn},
        user => $self->{config_db_centreon}->{username},
        password => $self->{config_db_centreon}->{password},
        force => 2,
        logger => $self->{logger}
    );
    $self->{db_centstorage} = gorgone::class::db->new(
        dsn => $self->{config_db_centstorage}->{dsn},
        user => $self->{config_db_centstorage}->{username},
        password => $self->{config_db_centstorage}->{password},
        force => 2,
        logger => $self->{logger}
    );

    ##### Load objects #####
    $self->{class_object_centreon} = gorgone::class::sqlquery->new(logger => $self->{logger}, db_centreon => $self->{db_centreon});
    $self->{class_object_centstorage} = gorgone::class::sqlquery->new(logger => $self->{logger}, db_centreon => $self->{db_centstorage});
    $self->{http} = gorgone::class::http::http->new(logger => $self->{logger});

    # Connect internal
    $connector->{internal_socket} = gorgone::standard::library::connect_com(
        zmq_type => 'ZMQ_DEALER',
        name => 'gorgone-anomalydetection',
        logger => $self->{logger},
        type => $self->{config_core}->{internal_com_type},
        path => $self->{config_core}->{internal_com_path}
    );
    $connector->send_internal_action(
        action => 'CENTREONADREADY',
        data => {}
    );
    $self->{poll} = [
        {
            socket  => $connector->{internal_socket},
            events  => ZMQ_POLLIN,
            callback => \&event,
        }
    ];
    while (1) {
        # we try to do all we can
        my $rev = zmq_poll($self->{poll}, 5000);
        if (defined($rev) && $rev == 0 && $self->{stop} == 1) {
            $self->{logger}->writeLogInfo("[anomalydetection] -class- $$ has quit");
            zmq_close($connector->{internal_socket});
            exit(0);
        }

        if (time() - $self->{resync_time} > $self->{last_resync_time}) {
            $self->{last_resync_time} = time();
            $self->action_adsync();
        }
    }
}

1;