package Mojolicious::Plugin::TrustedProxy;
use Mojo::Base 'Mojolicious::Plugin';
use Net::CIDR::Lite;
use Net::IP::Lite qw(ip_transform);
use Data::Validate::IP qw(is_ip is_ipv4_mapped_ipv6);

# https://github.com/Kage/Mojolicious-Plugin-TrustedProxy

our $VERSION = '0.02';

use constant DEBUG => $ENV{MOJO_TRUSTEDPROXY_DEBUG} || 0;

sub register {
  my ($self, $app, $conf) = @_;

  $app->log->debug(sprintf('[%s] VERSION = %s', __PACKAGE__, $VERSION))
    if DEBUG;

  # Set config defaults if undefined
# TODO
#  $conf->{support_rfc7239} //= 1;

  $conf->{ip_headers}      //= ['x-real-ip', 'x-forwarded-for'];
  $conf->{ip_headers}        = [$conf->{ip_headers}]
    unless ref($conf->{ip_headers}) eq 'ARRAY';

  $conf->{scheme_headers}  //= ['x-ssl', 'x-forwarded-proto'];
  $conf->{scheme_headers}    = [$conf->{scheme_headers}]
    unless ref($conf->{scheme_headers}) eq 'ARRAY';

  $conf->{https_values}    //= ['1', 'true', 'https', 'on', 'enable', 'enabled'];
  $conf->{https_values}      = [$conf->{https_values}]
    unless ref($conf->{https_values}) eq 'ARRAY';

  $conf->{parse_rfc7239}   //= ($conf->{parse_forwarded} // 1);

  $conf->{trusted_sources} //= ['127.0.0.0/8', '10.0.0.0/8'];
  $conf->{trusted_sources}   = [$conf->{trusted_sources}]
    unless ref($conf->{trusted_sources}) eq 'ARRAY';

  $conf->{hide_headers}    //= 0;

  # Assemble trusted source CIDR map
  my $cidr = Net::CIDR::Lite->new;
  foreach my $trust (@{$conf->{trusted_sources}}) {
    if (ref($trust) eq 'ARRAY') {
      $cidr->add_any(@$trust);
    } elsif (ref($trust) eq 'HASH') {
      $cidr->add_any(values(%$trust));
    } else {
      $cidr->add_any($trust);
    }
    $cidr->clean;
  }
  $app->defaults(
    'trustedproxy.conf' => $conf,
    'trustedproxy.cidr' => $cidr,
  );

  # Register helper
  $app->helper(is_trusted_source => sub {
    my $c = shift;
    my $ip = shift || $c->tx->original_remote_address || $c->tx->remote_address;
    my $cidr = $c->stash('trustedproxy.cidr');
    return undef unless
      is_ip($ip) && $cidr && $cidr->isa('Net::CIDR::Lite');
    $ip = ip_transform($ip, {convert_to => 'ipv4'}) if (is_ipv4_mapped_ipv6($ip));
    $c->app->log->debug(sprintf(
      '[%s] Testing if IP address "%s" is in trusted sources list',
      __PACKAGE__, $ip)) if DEBUG;
    return $cidr->find($ip);
  });

  # Register hook
  $app->hook(around_dispatch => sub {
    my ($next, $c) = @_;
    my $conf = $c->stash('trustedproxy.conf');
    return $next->() unless defined $conf;

    # Validate that the upstream source IP is within the CIDR map
    my $src_addr = $c->tx->remote_address;
    unless (defined $src_addr && $c->is_trusted_source($src_addr)) {
      $c->app->log->debug(sprintf(
        '[%s] %s not found in trusted_sources CIDR map',
        __PACKAGE__, $src_addr)) if DEBUG;
      return $next->();
    }

    # Set forwarded IP address from header
    foreach my $header (@{$conf->{ip_headers}}) {
      if (my $ip = $c->req->headers->header($header)) {
        if (lc $header eq 'x-forwarded-for') {
          my @xff = split /\s*,\s*/, $ip;
          $ip = $xff[0];
        }
        $c->app->log->debug(sprintf(
          '[%s] Matched on IP header "%s" (value: "%s")',
          __PACKAGE__, $header, $ip)) if DEBUG;
        $c->tx->original_remote_address($src_addr);
        $c->tx->remote_address($ip);
        last;
      }
    }

    # Set forwarded scheme from header
    foreach my $header (@{$conf->{scheme_headers}}) {
      if (my $scheme = $c->req->headers->header($header)) {
        if (!!$scheme && grep { lc $scheme eq $_ } @{$conf->{https_values}}) {
          $c->app->log->debug(sprintf(
            '[%s] Matched on HTTPS header "%s" (value: "%s")',
            __PACKAGE__, $header, $scheme)) if DEBUG;
          $c->req->url->base->scheme('https');
          last;
        }
      }
    }

    # Parse RFC-7239 ("Forwarded" header) if present
    if ($conf->{parse_rfc7239} && (my $fwd = $c->req->headers->header('forwarded'))) {
      my @pairs = map { split /\s*,\s*/, $_ } split ';', $fwd;
      my ($fwd_for, $fwd_by, $fwd_proto);
      my $ipv4_mask = qr/\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}/;
      my $ipv6_mask = qr/[\w:]+/;
      if ($pairs[0] =~ /(for|by)=($ipv4_mask)|(?:"?\[($ipv6_mask)\].*"?)/i) {
        $fwd_for = ($2 // $3) if lc $1 eq 'for';
        $fwd_by  = ($2 // $3) if lc $1 eq 'by';
      } elsif ($pairs[0] =~ /proto=(http|https)/i) {
        $fwd_proto = $1;
      }
      $c->tx->original_remote_address($fwd_by) if ($fwd_by && is_ip($fwd_by));
      $c->tx->remote_address($fwd_for)         if ($fwd_for && is_ip($fwd_for));
      $c->req->url->base->scheme($fwd_proto)   if $fwd_proto;
    }

    # Hide headers from the rest of the application
    if (!!$conf->{hide_headers}) {
      $c->app->log->debug(sprintf(
        '[%s] Removing headers from request', __PACKAGE__)) if DEBUG;
      $c->req->headers->remove($_) foreach @{$conf->{ip_headers}};
      $c->req->headers->remove($_) foreach @{$conf->{scheme_headers}};
    }

    # Carry on :)
    $next->();
  });

}

# For Desc:

#This plugin also supports parsing L<RFC 7239|http://tools.ietf.org/html/rfc7239>
#compliant C<Forwarded> headers and forwarded headers from
#L<Cloudflare|https://cloudflare.com>.

# For Config:

#=head2 support_rfc7239
#
#Enable support for parsing L<RFC 7239|http://tools.ietf.org/html/rfc7239>
#compliant C<Forwarded> HTTP headers. Default is C<1> (enabled).
#
#B<Note!> If enabled, the headers defined in L</ip_headers> and
#L</scheme_headers> will be ignored if the C<Forwarded> header is found.

1;
__END__
=head1 NAME

Mojolicious::Plugin::TrustedProxy - Mojolicious plugin to set the remote
address, connection scheme, and more from trusted upstream proxies

=head1 VERSION

Version 0.02

=head1 SYNOPSIS

  use Mojolicious::Lite;

  plugin 'TrustedProxy' => {
    ip_headers      => ['x-real-ip', 'x-forwarded-for'],
    scheme_headers  => ['x-ssl', 'x-forwarded-proto'],
    https_values    => ['1', 'true', 'https', 'on', 'enable', 'enabled'],
    trusted_sources => ['127.0.0.0/8', '10.0.0.0/8'],
    hide_headers    => 0,
  };

  get '/test' => sub {
    my $c = shift;
    $c->render(json => {
      'tx.remote_address'            => $c->tx->remote_address,
      'tx.original_remote_address'   => $c->tx->original_remote_address,
      'req.url.base.scheme'          => $c->req->url->base->scheme,
      'is_trusted_source'            => $c->is_trusted_source,
      'is_trusted_source("1.1.1.1")' => $c->is_trusted_source('1.1.1.1'),
    });
  };

  app->start;

=head1 DESCRIPTION

L<Mojolicious::Plugin::TrustedProxy> modifies every L<Mojolicious> request transaction
to override connecting user agent values only when the request comes from trusted
upstream sources. You can specify multiple request headers where trusted upstream
sources define the real user agent IP address or the real connection scheme, or
disable either, and can hide the headers from the rest of the application if
needed.

This plugin also supports parsing L<RFC 7239|http://tools.ietf.org/html/rfc7239>
compliant C<Forwarded>. Debug logging can be enabled by setting the
C<MOJO_TRUSTEDPROXY_DEBUG> environment variable.

Build status:

=begin html

<a href="https://travis-ci.org/Kage/Mojolicious-Plugin-TrustedProxy">
<img src="https://travis-ci.org/Kage/Mojolicious-Plugin-TrustedProxy.svg?branch=master">
</a>

=end html

=head1 CONFIG

=head2 ip_headers

List of zero, one, or many HTTP headers where the real user agent IP address
will be defined by the trusted upstream sources. The first matched header is
used. An empty value will disable this and keep the original scheme value.
Default is C<['x-real-ip', 'x-forwarded-for']>.

If a header is matched in the request, then C<< tx->remote_address >> is set to
the value, and C<< tx->original_remote_address >> is set to the IP address of the
upstream source.

=head2 scheme_headers

List of zero, one, or many HTTP headers where the real user agent connection
scheme will be defined by the trusted upstream sources. The first matched header
is used. An empty value will disable this and keep the original remote address
value. Default is C<['x-ssl', 'x-forwarded-proto']>.

This tests that the header value is "truthy" but does not contain the literal
barewords C<http>, C<off>, or C<false>. If the header contains any other
"truthy" value, then C<< req->url->base->scheme >> is set to C<https>.

=head2 https_values

List of values to consider as "truthy" when evaluating the headers in
L</scheme_headers>. Default is
C<['1', 'true', 'https', 'on', 'enable', 'enabled']>.

=head2 parse_rfc7239, parse_forwarded

Enable support for parsing L<RFC 7239|http://tools.ietf.org/html/rfc7239>
compliant C<Forwarded> HTTP headers. Default is C<1> (enabled).

B<Note!> If enabled, the headers defined in L</ip_headers> and
L</scheme_headers> will be overridden by any corresponding values found in
the C<Forwarded> header.

=head2 trusted_sources

List of one or more IP addresses or CIDR classes that are trusted upstream
sources. (B<Warning!> An empty value will trust from all IPv4 sources!) Default
is C<['127.0.0.0/8', '10.0.0.0/8']>.

Supports all IP, CIDR, and range definition types from L<Net::CIDR::Lite>.

=head2 hide_headers

Hide all headers defined in L</ip_headers> and L</scheme_headers> from the rest
of the application when coming from trusted upstream sources. Default is C<0>
(disabled).

=head1 HELPERS

=head2 is_trusted_source

  # From Controller context
  sub get_page {
    my $c = shift;
    if ($c->is_trusted_source || $c->is_trusted_source('1.2.3.4')) {
      ...
    }
  }

Validate if an IP address is in the L</trusted_sources> list. If no argument is
provided, then this helper will first check C<< tx->original_remote_address >>
then C<< tx->remote_address >>. Returns C<1> if in the L</trusted_sources> list,
C<0> if not, or C<undef> if the IP address is invalid.

=head1 CDN AND CLOUD SUPPORT

L<Mojolicious::Plugin::TrustedProxy> is compatible with assumedly all
third-party content delivery networks and cloud providers. Below is an
incomplete list of some of the most well-known providers and the recommended
L<config|/CONFIG> values to use for them.

=head2 Akamai

=over

=item ip_headers

Set L</ip_headers> to C<['true-client-ip']> (unless you set this to a different
value) and enable True Client IP in the origin server behavior for your site
property. Akamai also supports C<['x-forwarded-for']>, which is enabled by
default in L<Mojolicious::Plugin::TrustedProxy>.

=item scheme_headers

There is no known way to pass this by default with Akamai. It may be possible
to pass a custom header via a combination of a Site Property variable and a
custom behavior that injects an outgoing request header based on that variable,
but this has not been tested or confirmed.

=item trusted_sources

This is only possible if you have the
L<Site Shield|https://www.akamai.com/us/en/products/security/site-shield.jsp>
product from Akamai. If so, set L</trusted_sources> to the complete list of
IPs provided in your Site Shield map.

=back

=head2 AWS

=over

=item ip_headers

The AWS Elastic Load Balancer uses C<['x-forwarded-for']>, which is enabled by
default in L<Mojolicious::Plugin::TrustedProxy>.

=item scheme_headers

The AWS Elastic Load Balancer uses C<['x-forwarded-proto']>, which is enabled
by default in L<Mojolicious::Plugin::TrustedProxy>.

=item trusted_sources

Depending on your setup, this could be one of the C<172.x.x.x> IP addresses
or ranges within your Virtual Private Cloud, the IP address(es) of your Elastic
or Application Load Balancer, or could be the public IP ranges for your AWS
region. Go to
L<https://docs.aws.amazon.com/general/latest/gr/aws-ip-ranges.html> for an
updated list of AWS's IPv4 and IPv6 CIDR ranges.

=back

=head2 Cloudflare

=over

=item ip_headers

Set L</ip_headers> to C<['cf-connecting-ip']>, or C<['true-client-ip']> if
using an enterprise plan. Cloudflare also supports C<['x-forwarded-for']>,
which is enabled by default in L<Mojolicious::Plugin::TrustedProxy>.

=item scheme_headers

Cloudflare uses the C<x-forwarded-proto> header, which is enabled by default
in L<Mojolicious::Plugin::TrustedProxy>.

=item trusted_sources

Go to L<https://www.cloudflare.com/ips/> for an updated list of Cloudflare's
IPv4 and IPv6 CIDR ranges.

=back

=head1 AUTHOR

Kage <kage@kage.wtf>

=head1 BUGS

Please report any bugs or feature requests on Github:
L<https://github.com/Kage/Mojolicious-Plugin-TrustedProxy>

=head1 SEE ALSO

L<Mojolicious::Plugin::RemoteAddr>, L<Mojolicious::Plugin::ClientIP::Pluggable>,
L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=head1 COPYRIGHT

MIT License

Copyright (c) 2019 Kage

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut