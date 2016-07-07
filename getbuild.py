#!/usr/bin/env python
""""Retrieves UnboundID builds from the Nexus repository.
Should work with Python 2.4, which means it should run on Solaris 10 and CentOS 5.5.

NOTE: After making changes, please ensure that getbuildtest passes.
"""

__version__ = "1.2.6"

#######################################################################
#
# Configuration
#
#######################################################################

# Nexus REST API settings
RELEASE_REPOSITORY_BASE_URI = "http://hudson:8081/nexus/service/local/repositories"
ENG_REPOSITORY_BASE_URI = "http://maven-eng:8080/nexus/service/local/repositories"

# HTTP client settings
HTTP_USER_AGENT = "getbuild/%s" % __version__
HTTP_TIMEOUT = 60         # seconds
CHUNK_SIZE = 16 * 1024    # bytes

# HTTP auth settings
HTTP_AUTH_REALM = "Sonatype Nexus Repository Manager API"
HTTP_AUTH_SERVER = 'hudson:8081'
HTTP_AUTH_USERNAME = ''
HTTP_AUTH_PASSWORD = ''

import datetime
import operator
import os
import re
import sys
import time
import urllib2
import xml.dom.minidom
from distutils.version import LooseVersion as VersionNumber
from optparse import OptionParser, BadOptionError, AmbiguousOptionError
from urllib2 import HTTPError

#######################################################################
#
# Everything else
#
#######################################################################

class PassThroughOptionParser(OptionParser):
  """
  An unknown option pass-through implementation of OptionParser.

  When unknown arguments are encountered, bundle with largs and try again,
  until rargs is depleted.

  sys.exit(status) will still be called if a known argument is passed
  incorrectly (e.g. missing arguments or bad argument types, etc.)
  """
  def _process_args(self, largs, rargs, values):
    while rargs:
      try:
        OptionParser._process_args(self,largs,rargs,values)
      except (BadOptionError, AmbiguousOptionError), e:
        largs.append(e.opt_str)

  def format_option_help(self, formatter=None):
    return ""

def fail(error_message):
  """Writes an error message to STDERR and exits."""
  sys.stderr.write(
      AnsiColor.colorize(AnsiColor.RED, "FAILURE: ") + \
      error_message + "\n"
  )
  sys.exit(1)

def parse_date(date_str):
  """Parses a date from the command line into a Datetime object."""
  fmt = "%Y-%m-%d"
  return datetime.datetime(*time.strptime(date_str, fmt)[:6])

class BuildTypeError(StandardError):
  def __init__(self):
    self.value = "A repository build type can only be one of: %s" % \
                  ', '.join(RepositoryTypes.BUILD_TYPES)

  def __str__(self):
    return repr(self.value)

class RepositoryTypeError(StandardError):
  def __init__(self):
    self.value = "A repository type can only be one of: %s" % \
                  ', '.join(RepositoryTypes.BUILD_TYPES)

  def __str__(self):
    return repr(self.value)

class ProductTypeError(StandardError):
  def __init__(self):
    self.value = "A product can only be one of: %s" % \
                  ', '.join(RepositoryTypes.PRODUCTS)

  def __str__(self):
    return repr(self.value)

class AnsiColor(object):
  """Provides simple support for colorizing console text."""
  RESET  = '\x1b[0m'
  BOLD   = '\x1b[1m'
  BLACK  = '\x1b[30m'
  RED    = '\x1b[31m'
  GREEN  = '\x1b[32m'
  YELLOW = '\x1b[33m'
  BLUE   = '\x1b[34m'
  PURPLE = '\x1b[35m'
  CYAN   = '\x1b[36m'
  WHITE  = '\x1b[37m'

  @staticmethod
  def colorize(color, text):
    """Returns the provided text wrapped in the desired ANSI color sequence."""
    return "%s%s%s" % (color, text, AnsiColor.RESET)

class HTTPUtil(object):
  @staticmethod
  def fetch(uri, name=None, fn=None, quiet=False):
    """GETs the specified URI.

    If 'fn' is specified as a filename, then it is assumed that the resource
    being requested should be saved to disk; in this case, the actual filename
    is returned. If 'fn' is not specified, then nothing is saved to disk, and
    the resource is returned as a string.
    """
    if not quiet:
      if name is not None:
        print AnsiColor.colorize(AnsiColor.BLUE, "Fetching ") + name
      else:
        print AnsiColor.colorize(AnsiColor.BLUE, "Fetching ") + uri
    auth_handler = urllib2.HTTPBasicAuthHandler()
    auth_handler.add_password(
          HTTP_AUTH_REALM, 
          HTTP_AUTH_SERVER,
          HTTP_AUTH_USERNAME,
          HTTP_AUTH_PASSWORD
    )
    opener = urllib2.build_opener(auth_handler)
    opener.addheaders = [('User-Agent', HTTP_USER_AGENT)]
    urllib2.install_opener(opener)
    try:
      resource = urllib2.urlopen(uri)
      if not fn:
          data = resource.read()
          resource.close()
          return data
      else:
        return HTTPUtil._download_file_like_object(resource, fn, quiet)
    except HTTPError, e:
      http_error = " ".join([str(e.code), e.msg])
      if e.code == 404:
        fail("The requested build could not be found at the URL: %s" % uri)
      else:
        fail(http_error)

  @staticmethod
  def _download_file_like_object(o, fn, quiet=False):
    """Given an open file-like object 'o', writes it to the filename 'fn'
    and returns the filename."""
    download_size = None
    count = 0
    if o.info() is not None:
      download_size = int(o.info()['Content-Length'])
    f = open(fn, 'wb')
    try:
      for data in iter(lambda: o.read(CHUNK_SIZE), ''):
        count += 1
        if not quiet and download_size is not None:
          HTTPUtil._print_download_progress(count, CHUNK_SIZE, download_size)
        f.write(data)
    finally:
      if not quiet:
        print "\n"
      f.close()
    return fn

  @staticmethod
  def _print_download_progress(count, chunk_size, total_size):
    """Prints out download status."""
    percent = int((count * chunk_size * 100) / total_size)
    if percent > 100:
      percent = 100
    sys.stdout.write("\r" + AnsiColor.colorize(AnsiColor.CYAN, "Downloading... ")
                     + "%2d%%" % percent)
    sys.stdout.flush()

# TODO: Special-case information about each product should live here rather than in the download code.
class RepositoryTypes(object):
  BUILD_TYPES = [ "snapshot", "release" ]

  REPOSITORY_TYPES = [ "release", "eng" ]

  PUBLIC_PRODUCTS = [
      "ds", "proxy", "sync", "metrics", "broker",
      "ds-web-console", "proxy-web-console",
      "sync-web-console", "metrics-web-console",
      "broker-web-console",
      "server-sdk", "ldapsdk",
      "scim-ri", "scim-sdk"
  ]

  INTERNAL_PRODUCTS = [
      "qa-tools", "texas-mgmt-node",
      "test-node", "test-node-plugins",
      "broker-test-tool", "ssam", "connecticut"
  ]

  PRODUCTS = PUBLIC_PRODUCTS + INTERNAL_PRODUCTS

class RepositoryURI(object):
  """Represents a URI for a resource in the Nexus artifact repository."""

  def __init__(self, build_type=None, product=None,
      version=None, qualifier=None, organization=None):
    self.build_type = build_type
    self.product = product
    self.version = version
    self.qualifier = qualifier
    self.organization = organization
    self.repository_type = None

  def with_build_type(self, build_type):
    self.build_type = build_type
    if self.build_type not in RepositoryTypes.BUILD_TYPES:
      raise BuildTypeError
    if self.build_type == 'release':
      self.qualifier = 'GA'
    return self

  def with_repository_type(self, repository_type):
    self.repository_type = repository_type
    if self.repository_type not in RepositoryTypes.REPOSITORY_TYPES:
      raise RepositoryTypeError
    return self

  def with_product(self, product):
    self.product = product
    if self.product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    return self

  def with_version(self, version):
    self.version = version
    return self

  def with_qualifier(self, qualifier):
    self.qualifier = qualifier
    return self

  def with_organization(self, organization):
    self.organization= organization
    return self

  def get_version_uri_suffix(self):
    version = ""

    # Don't default to a GA build if the product is internal or ldapsdk, scim-sdk, or scim-ri
    default_to_ga = self.product in set(RepositoryTypes.PUBLIC_PRODUCTS).difference({'ldapsdk', 'scim-sdk', 'scim-ri'})

    if self.version:
      version = self.version
      qualifier = self.qualifier

      # Default to LDAP SDK CE, then throw away qualifier so it doesn't get repeated
      if self.product == 'ldapsdk':
        if not ('-ce' in version or '-se' in version):
          version += qualifier if qualifier else '-ce'
          qualifier = None

      if self.build_type == "snapshot":
        version += ('_' + qualifier + '-SNAPSHOT') if qualifier else '-SNAPSHOT'
      if self.build_type == "release":
        version += ("-" + qualifier) if qualifier else '-GA' if default_to_ga else ''

    return version

  def uri_data(self):
    # SCIM artifacts after version 1.0.0 are stored with the
    # "com.unboundid.scim.qa" groupId.
    new_scim_groupId = self.product.startswith('scim') and \
                       (self.version is None or VersionNumber(self.version) > VersionNumber("1.0.0"))

    # Directory/Sync/Proxy/Metrics artifact URLs after a certain version use
    # a different path scheme. Now, the product name is prepended with
    # "ds/", and the "ds" product is identified as "directory".
    new_artifact_path = not self.product in ['scim-sdk', 'scim-ri', 'ldap-sdk'] and \
                        (self.version is None or VersionNumber(self.version) > VersionNumber("3.2.0.0"))
    repository_uri = {
      "eng": ENG_REPOSITORY_BASE_URI,
      "release": RELEASE_REPOSITORY_BASE_URI
    }
    build_types = {
      "snapshot": "snapshots/content",
      "release": "releases/content"
    }
    # To add another product, create a property in the appropriate parent element (eng or release).
    # The property's value should be its Nexus URI.

    # For a "release" product, the {org} tag should be included to specify which organizational version of the product
    # should be retrieved at runtime. The {opt} tag is optional and can be used when the URI needs modification
    # according to some special factors (e.g. adding "qa/" to the URI for the newer SCIM releases).

    product_paths = {
      # Special path handling for internal products.
      "eng": {
        "texas-mgmt-node": "com/unboundid/qa/texas/node/mgmt/texas-mgmt-node",
        "test-node": "com/unboundid/qa/florida/test-node",
        "test-node-plugins": "com/unboundid/qa/florida/test-node-plugins",
        "broker-test-tool": "com/unboundid/qa/tools/broker/broker-test-tool",
        "ssam": "com/unboundid/webapp/ssam"
      },

      # Special path handling for public products.
      # {org} will be replaced with the self.organization property.
      # {opt} will be replaced with 'qa/', 'ds/', or '', depending on the values of
      #   new_scim_groupId and new_artifact_path
      "release": {
        "ds": "com/{org}/product/{opt}directory",
        "proxy": "com/{org}/product/{opt}proxy",
        "sync": "com/{org}/product/{opt}sync",
        "metrics": "com/{org}/product/{opt}metrics",
        "broker": "com/{org}/product/{opt}broker",
        "ds-web-console": "com/{org}/product/{opt}ds-web-console",
        "proxy-web-console": "com/{org}/product/{opt}proxy-web-console",
        "sync-web-console": "com/{org}/product/{opt}sync-web-console",
        "metrics-web-console": "com/{org}/product/{opt}metrics-web-console",
        "broker-web-console": "com/{org}/product/{opt}broker-web-console",
        "server-sdk": "com/{org}/product/{opt}server-sdk",
        "scim-sdk": "com/{org}/product/scim/{opt}scim-sdk",
        "scim-ri": "com/{org}/product/scim/{opt}scim-ri",
        "ldapsdk": "com/{org}/product/ldapsdk"
      }
    }

    return (new_scim_groupId, new_artifact_path, repository_uri, build_types,
    product_paths)

  @property
  def uri(self):
    (new_scim_groupId, new_artifact_path, repository_uri, build_types,
     product_paths) = self.uri_data()

    uri = "{base_uri}/{build_type}/{product_path}/{version}"
    props = {
      "version": "",  # version is optional
      "base_uri": repository_uri.get(self.repository_type),
      "build_type": build_types.get(self.build_type)
    }

    product = self.product

    if product:
      """" Get product URI. """""
      paths = product_paths.get(self.repository_type)
      # Assume that most internal products to be downloaded will be test tools.
      product_path = paths.get(product, "com/unboundid/directory/testtools/" + product)

      """" Use flags from uri_data() to format the URI appropriately. """""
      format_org = self.organization.lower()
      # Use the flags 'new_scim_groupId' and 'new_artifact_path' to adjust the URI
      format_opt = "qa/" if new_scim_groupId else "ds/" if new_artifact_path else ""
      props["product_path"] = product_path.format(org=format_org, opt=format_opt)

      """" Append a version suffix to the URI, if necessary. """""
      version = self.get_version_uri_suffix()
      props["version"] = version

    return uri.format(**props)

  def __str__(self):
    return self.uri

class Repository(object):
  """A Nexus build artifact repository."""

  def __init__(self, build_type, repository_type, organization="UnboundID"):
    self.build_type = build_type
    if self.build_type not in RepositoryTypes.BUILD_TYPES:
      raise BuildTypeError
    self.repository_type = repository_type
    if self.repository_type not in RepositoryTypes.REPOSITORY_TYPES:
      raise RepositoryTypeError
    self.uri = RepositoryURI().with_build_type(build_type) \
                              .with_repository_type(repository_type) \
                              .with_organization(organization)

  @staticmethod
  def _find_version(text):
    """Attempts to match on a version string. Returns an re.Match object where
    group 1 is the version number and group 5 is the build type."""
    rx = re.compile(r"((\d\.)+(\d)+)(-((SNAPSHOT)|((ce|se)-SNAPSHOT)|((c|s)e)|(GA)|(RC\d+)))?$")
    return rx.search(text)

  def get_versions(self, product, quiet=False):
    """Gets the list of available versions for the specified product."""
    if product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    self.uri = self.uri.with_product(product)
    res = HTTPUtil.fetch(self.uri.uri, quiet=quiet)

    dom = xml.dom.minidom.parseString(res)

    versions = []
    items = dom.getElementsByTagName("content-item")
    for item in items:
      text = item.getElementsByTagName("text")[0].firstChild.data
      version_match = self._find_version(text)
      if version_match:
        versions.append(VersionNumber(version_match.group(1)))
    versions.sort(reverse=True)
    return versions

  def get_artifacts(self, product, version, qualifier, package_type,
                    quiet=False):
    """Gets the list of available artifacts with the specified product, 
    version, and qualifier."""
    # This check is performed in main(), but is repeated here because this
    # method may be called independently of main(); e.g., from the Python REPL.
    if product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    self.uri = self.uri.with_product(product).with_version(version) \
                       .with_qualifier(qualifier)
    res = HTTPUtil.fetch(self.uri.uri, quiet=quiet)

    dom = xml.dom.minidom.parseString(res)

    artifacts = []
    items = dom.getElementsByTagName("content-item")
    for item in items:
      text = item.getElementsByTagName("text")[0].firstChild.data
      last_modified = item.getElementsByTagName("lastModified")[0].firstChild.data
      uri = item.getElementsByTagName("resourceURI")[0].firstChild.data
      artifact = Artifact(text, uri, last_modified)
      if artifact.is_build(package_type):
        artifacts.append(artifact) 
    artifacts.sort(
        key=operator.attrgetter('last_modified_parsed'),
        reverse=True
    )
    # for artifact in artifacts:
    #   print "Build artifact: %s" % artifact.text
    return artifacts

  def get_from_date(self, product, version, qualifier, package_type, build_date,
                    quiet=False):
    """Returns the latest Artifact with the given last-modified date and with
    the specified product, version, and qualifier."""
    artifacts = self.get_artifacts(product, version, qualifier, package_type,
                                   quiet=quiet)
    for artifact in artifacts:
      if build_date.date() == artifact.last_modified_parsed.date():
        return artifact
    fail("The requested build could not be found.")

  def get_latest(self, product, version, qualifier, package_type, quiet=False):
    """Returns the latest Artifact by last-modified date with the specified
    product, version, and qualifier."""
    try:
      return self.get_artifacts(product, version, qualifier, package_type,
                                quiet=quiet)[0]
    except IndexError:
      fail("Failed to retrieve artifact versions.")

  def get_latest_from_pattern(self, product, version_pattern, qualifier,
                              package_type, quiet=False):
    """Returns the latest Artifact matching the given version pattern. The
    version pattern should use 'x' as a wildcard for the rightmost version
    component. For example, the pattern "4.7.0.x" might match for version
    4.7.0.3."""
    all_versions = self.get_versions(product, quiet=quiet)
    rx = re.compile(r"(%s)" % version_pattern.replace('x', r"(\d{1,2})$"))
    for version in all_versions:
      if rx.match(version.vstring):
        return self.get_latest(product, version.vstring, qualifier,
                               package_type, quiet=quiet)
    fail("A build matching the pattern '%s' could not be found." % version_pattern)

class Artifact(object):
  """A build artifact."""

  def __init__(self, text, uri, last_modified):
    self.text = text
    self.uri = uri
    self.last_modified = last_modified
    self.last_modified_parsed = self._str_to_datetime(self.last_modified)

  @staticmethod
  def _str_to_datetime(s):
    # Last-modified dates in the Nexus API look like this: "2011-08-03 01:02:49.0 CDT"
    # The Python 2.4 time/datetime modules don't support microseconds, unfortunately.
    # We handle this by cheating and stripping out the microseconds AND the
    # timezone. This avoids error-prone regexes, and it should be harmless.
    stripped = s.split(".")[0]
    fmt = "%Y-%m-%d %H:%M:%S"
    # And because we target Python 2.4, there's no readable way to convert a date
    # string into a Datetime object.
    return datetime.datetime(*time.strptime(stripped, fmt)[:6])

  def is_build(self, package_type):
    """Returns true if the artifact is a build, here defined as having a URI
    with extension 'package_type' (usually 'zip').

    This will also return false for builds lacking BDB JE."""
    extension = "." + package_type
    # For the jar package type, we only ever want a jar with dependencies.
    if package_type == "jar":
      return self.uri.endswith("-jar-with-dependencies.jar")
    return self.uri.endswith(extension) and "no-je" not in self.uri

  def download(self, fn=None, quiet=False):
    """Saves the build artifact to disk.

    An optional filename may be specified."""
    if fn is None:
      filename = self.text
    else:
      filename = fn
    HTTPUtil.fetch(self.uri, name=self.text, fn=filename, quiet=quiet)

def _parse_args(argv):
  scriptname = os.path.basename(argv[0])
  is_alu = scriptname == "getalubuild" or scriptname == "getalubuild.py"
  get_rpm = scriptname == "getrpmbuild" or scriptname == "getrpmbuild.py"
  if get_rpm:
    package_type = "rpm"
  else:
    package_type = "zip"

  parser = PassThroughOptionParser(usage=_usage())

  parser.add_option("-f", "--from", dest="build_date")
  parser.add_option("-q", "--quiet", action="store_true", dest="quiet", default=False)
  parser.add_option("-p", "--print-url-only", action="store_true", dest="print_url_only", default=False)
  valid_destinations = ['build_date', 'print_url_only', 'quiet']

  # OptionParser will fail if it encounters the value None. Replace None with '' during parsing.
  argv = [(arg if arg else '') for arg in argv]
  # Parse options.
  (options, args) = parser.parse_args(args=argv)
  # Put None back in.
  args = [(None if arg == '' else arg) for arg in args]

  # Check for invalid usage
  if any(x not in valid_destinations for x in vars(options).keys()) or len(vars(options).keys()) > 3:
    _usage()


  try:
    quiet = options.quiet
    print_url_only = options.print_url_only

    build_date = options.build_date
    if build_date:
      try:
        build_date = parse_date(build_date)
      except ValueError:
        fail("Build date should be in the format YYYY-MM-DD.")

    (build_type, product, version) = ('snapshot', None, 'latest')
    not_version_number = re.compile('.*[a-wA-WyzYZ]+')
    args_copy = list(args)
    for arg in args[1:]:
        if arg is None:
            continue

        if arg.lower() in RepositoryTypes.BUILD_TYPES:
            build_type = arg.lower()
            args_copy.remove(arg)
        elif arg in RepositoryTypes.PRODUCTS:
            product = arg
            args_copy.remove(arg)
        elif not not_version_number.match(arg) or arg.lower() == 'latest':  # if arg matches version number o
            version = arg
            args_copy.remove(arg)

    qualifier = args_copy[1] if len(args_copy) >= 2 else None

    if build_type not in RepositoryTypes.BUILD_TYPES:
      raise BuildTypeError
    if product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    if product in RepositoryTypes.INTERNAL_PRODUCTS:
      repository_type = 'eng'
    else:
      repository_type = 'release'

    if is_alu:
      organization = "ALU"
    else:
      organization = "UnboundID"

    # If LDAP SDK edition is not specified, assume Commercial Edition
    if product == 'ldapsdk':
      ldapsdk_version_rx = re.compile(r'(.+)-([a-z]e(.*))$')
      if ldapsdk_version_rx.search(version) is None:
        version += "-ce"

    # Some test artifacts are only available as jars.
    if product == 'test-node-plugins' or product == 'connecticut':
      package_type = "jar"

    return build_type, repository_type, organization, product, version, \
           qualifier, package_type, build_date, print_url_only, quiet
  except:
    print _usage()
    sys.exit(0)

def _get_artifact(repository, product, version, qualifier, package_type,
                  build_date, quiet):
  if 'latest' in version.lower():
    latest_version = repository.get_versions(product, quiet=quiet)[0].vstring
    artifact = repository.get_latest(product, latest_version, qualifier,
                               package_type, quiet=quiet)
  elif version.endswith(".x"):
    artifact = repository.get_latest_from_pattern(product, version, qualifier,
                                                  package_type, quiet=quiet)
  else:
    if build_date is not None:
      artifact = repository.get_from_date(product, version, qualifier,
                                          package_type, build_date, quiet=quiet)
    else:
      artifact = repository.get_latest(product, version, qualifier, package_type,
                                       quiet=quiet)
  return artifact


def _usage():
  usage = "Usage: getbuild PRODUCT [ARGUMENTS]\n" + \
    "Download the latest build from the Nexus artifact repository.\n" + \
    "Example: getbuild broker\n\n" + \
    "Example: getbuild ds snapshot 3.2.0.0 M1\n\n" + \
 \
    "  ARGUMENTS              BUILD_TYPE, VERSION, QUALIFIER, or OPTION\n" + \
    "  BUILD_TYPE             'snapshot' (default) or 'release'\n" + \
    "  PRODUCT                supported products:\n" + \
    _get_product_list() + \
    "  VERSION                for example, '4.7.0.3', '4.7.0.x', or 'latest' (default)\n" + \
    "  QUALIFIER              i.e., 'I2' (Note: 'GA' may be omitted)\n\n" + \
   \
    "OPTIONS:\n" + \
    "  -q, --quiet              Suppress output.\n" + \
    "  -p, --print-url-only     Prints the artifact URL without downloading it.\n" + \
    "  -f, --from YYYY-MM-DD    Downloads the latest build from the given date.\n\n" + \
    "If you run this script as 'getalubuild', it will retrieve an \n" + \
    "Alcatel-Lucent build instead of an UnboundID build.\n" + \
    "Running this script as 'getrpmbuild' will cause it to retrieve an\n" + \
    "UnboundID RPM build instead of a zip.\n"

  return usage


def _get_product_list():
  list_len = len(RepositoryTypes.PRODUCTS)

  # Calculates optimal column width based on word length
  col_width = 10
  for i in range(list_len):
    max_word_len = len(RepositoryTypes.PRODUCTS[i]) + 2
    if col_width < (max_word_len):
      col_width = max_word_len

  # Prints products in the PRODUCTS list
  products_per_line = 2
  product_list = ""

  for n in range(list_len):
    if n % products_per_line == 0:
        product_list += ' ' * 26
    product_list += RepositoryTypes.PRODUCTS[n].ljust(col_width)
    if (n+1) % products_per_line == 0 or (n+1) == list_len:
        product_list += '\n'

  return product_list

def main():
  (build_type, repository_type, organization, product, version, qualifier,
   package_type, build_date, print_url_only, quiet) = _parse_args(sys.argv)

  try:
    repo = Repository(build_type, repository_type, organization)
    try:
      artifact = _get_artifact(repo, product, version, qualifier, package_type,
                               build_date, quiet)
      if not print_url_only:
        artifact.download(quiet=quiet)
      else:
        print artifact.uri
    except KeyboardInterrupt:
      sys.stderr.write("\nDownload cancelled.\n")
  except (BuildTypeError, ProductTypeError), e:
    fail(str(e))

if __name__ == "__main__":
  main()

