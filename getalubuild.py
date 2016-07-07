#!/usr/bin/env python
""""Retrieves UnboundID builds from the Nexus repository.
Should work with Python 2.4, which means it should run on Solaris 10 and CentOS 5.5.
"""

__version__ = "1.2.4"

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
from urllib2 import HTTPError

#######################################################################
#
# Everything else
#
#######################################################################


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
  def fetch(uri, name=None, fn=None, verbose=False):
    """GETs the specified URI.

    If 'fn' is specified as a filename, then it is assumed that the resource
    being requested should be saved to disk; in this case, the actual filename
    is returned. If 'fn' is not specified, then nothing is saved to disk, and
    the resource is returned as a string.
    """
    if verbose:
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
        return HTTPUtil._download_file_like_object(resource, fn, verbose)
    except HTTPError, e:
      http_error = " ".join([str(e.code), e.msg])
      if e.code == 404:
        fail("The requested build could not be found at the URL: %s" % uri)
      else:
        fail(http_error)

  @staticmethod
  def _download_file_like_object(o, fn, verbose=False):
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
        if verbose and download_size is not None:
          HTTPUtil._print_download_progress(count, CHUNK_SIZE, download_size)
        f.write(data)
    finally:
      if verbose:
        print "\n"
      f.close()
    return fn

  @staticmethod
  def _print_download_progress(count, chunk_size, total_size):
    """Prints out download status."""
    percent = int((count * chunk_size * 100) / total_size)
    sys.stdout.write("\r" + AnsiColor.colorize(AnsiColor.CYAN, "Downloading... ")
                     + "%2d%%" % percent)
    sys.stdout.flush()

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
      "broker-test-tool"
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

  @property
  def uri(self):
    uri = []
    if self.repository_type == 'eng':
      uri.append(ENG_REPOSITORY_BASE_URI)
    else:
      uri.append(RELEASE_REPOSITORY_BASE_URI)
    if self.build_type == "snapshot":
      uri.append("/snapshots/content")
    if self.build_type == "release":
      uri.append("/releases/content")
    if self.product is not None:
      if self.repository_type == 'eng':
        # Special path handling for internal products.
        if self.product == "texas-mgmt-node":
          uri.append("/com/unboundid/qa/texas/node/mgmt/")
        elif self.product in ["test-node", "test-node-plugins"]:
          uri.append("/com/unboundid/qa/florida/")
        elif self.product == "broker-test-tool":
          uri.append("/com/unboundid/qa/tools/broker/")
        else:
          # Assume that most internal products to be downloaded 
          # will be test tools.
          uri.append("/com/unboundid/directory/testtools/")
        uri.append(self.product)
      else:
        # Special path handling for public products.
        if self.organization.lower() == "alu":
          uri.append("/com/alu/product/")
        else:
          uri.append("/com/unboundid/product/")
        # SCIM artifacts after version 1.0.0 are stored with the 
        # "com.unboundid.scim.qa" groupId.
        if self.product.startswith('scim'):
          uri.append("scim/")
          if self.version is None or VersionNumber(self.version) > VersionNumber("1.0.0"):
            uri.append("qa/")
        # Directory/Sync/Proxy/Metrics artifact URLs after a certain version use 
        # a different path scheme. Now, the product name is prepended with 
        # "ds/", and the "ds" product is identified as "directory".
        if self.version is None or VersionNumber(self.version) > VersionNumber("3.2.0.0"):
            if self.product not in [ "scim-sdk", "scim-ri", "ldapsdk" ]:
              uri.append("ds/")
            if self.product == "ds":
              uri.append("directory")
            else:
              uri.append(self.product)
        else:
          uri.append(self.product)
      if self.version is not None:
        uri.append("/")
        uri.append(self.version)
        if self.build_type == "snapshot":
          if self.qualifier is not None:
            uri.append("_")
            uri.append(self.qualifier)
          uri.append("-SNAPSHOT")
        if self.build_type == "release" and \
            self.product != "ldapsdk" and \
            not self.product.startswith('scim'):
          uri.append("-GA")
    uri.append("/")
    return "".join(uri)

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
    rx = re.compile(r"((\d\.)+(\d))(-((SNAPSHOT)|(GA)|(RC\d+)))?$")
    return rx.search(text)

  def get_versions(self, product, verbose=False):
    """Gets the list of available versions for the specified product."""
    if product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    self.uri = self.uri.with_product(product)
    res = HTTPUtil.fetch(self.uri.uri, verbose=verbose)

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
                    verbose=False):
    """Gets the list of available artifacts with the specified product, 
    version, and qualifier."""
    # This check is performed in main(), but is repeated here because this
    # method may be called independently of main(); e.g., from the Python REPL.
    if product not in RepositoryTypes.PRODUCTS:
      raise ProductTypeError
    self.uri = self.uri.with_product(product).with_version(version) \
                       .with_qualifier(qualifier)
    res = HTTPUtil.fetch(self.uri.uri, verbose=verbose)

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
                    verbose=False):
    """Returns the latest Artifact with the given last-modified date and with
    the specified product, version, and qualifier."""
    artifacts = self.get_artifacts(product, version, qualifier, package_type,
                                   verbose=verbose)
    for artifact in artifacts:
      if build_date.date() == artifact.last_modified_parsed.date():
        return artifact
    fail("The requested build could not be found.")

  def get_latest(self, product, version, qualifier, package_type, verbose=False):
    """Returns the latest Artifact by last-modified date with the specified 
    product, version, and qualifier."""
    return self.get_artifacts(product, version, qualifier, package_type,
                              verbose=verbose)[0]

  def get_latest_from_pattern(self, product, version_pattern, qualifier,
                              package_type, verbose=False):
    """Returns the latest Artifact matching the given version pattern. The
    version pattern should use 'x' as a wildcard for the rightmost version
    component. For example, the pattern "4.7.0.x" might match for version
    4.7.0.3."""
    all_versions = self.get_versions(product, verbose=verbose)
    rx = re.compile(r"(%s)" % version_pattern.replace('x', r"(\d{1,2})$"))
    for version in all_versions:
      if rx.match(version.vstring):
        return self.get_latest(product, version.vstring, qualifier,
                               package_type, verbose=verbose)
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
    return self.uri.endswith(extension) and "no-je" not in self.uri

  def download(self, fn=None, verbose=False):
    """Saves the build artifact to disk.

    An optional filename may be specified."""
    if fn is None:
      filename = self.text
    else:
      filename = fn
    HTTPUtil.fetch(self.uri, name=self.text, fn=filename, verbose=verbose)

def _usage():
  # TODO: Generate list of products dynamically using PRODUCTS
  print "Usage: getbuild [OPTIONS] BUILD_TYPE PRODUCT VERSION [QUALIFIER]"
  print "Download the latest build from the Nexus artifact repository."
  print "Example: getbuild snapshot ds 3.2.0.0 M1"
  print 
  print "  BUILD_TYPE             'snapshot' or 'release'"
  print "  PRODUCT                'ds', 'proxy', 'sync', 'metrics', 'broker',"
  print "                           'ds-web-console', 'proxy-web-console', "
  print "                           'sync-web-console', 'metrics-web-console', "
  print "                           'broker-web-console', 'ldapsdk',"
  print "                           'server-sdk', 'scim-ri', 'scim-sdk',"
  print "                           'texas-mgmt-node', 'qa-tools',"
  print "                           'broker-test-tool',"
  print "                           'test-node', or 'test-node-plugins'"
  print "  VERSION                for example, '4.7.0.3', '4.7.0.x', or 'latest'"
  print "  QUALIFIER              i.e., 'I2' (Note: 'GA' may be omitted)"
  print
  print "OPTIONS:"
  print "  --verbose              Enables verbose output."
  print "  --print-url-only       Prints the artifact URL without downloading it."
  print "  --from YYYY-MM-DD      Downloads the latest build from the given date."
  print
  print "If you run this script as 'getalubuild', it will retrieve an "
  print "Alcatel-Lucent build instead of an UnboundID build."
  print "Running this script as 'getrpmbuild' will cause it to retrieve an "
  print "UnboundID RPM build instead of a zip."
  sys.exit(0)

def main():
  scriptname = os.path.basename(__file__)
  is_alu = scriptname == "getalubuild" or scriptname == "getalubuild.py"
  get_rpm = scriptname == "getrpmbuild" or scriptname == "getrpmbuild.py"
  if get_rpm:
    package_type = "rpm"
  else:
    package_type = "zip"

  verbose = False
  print_url_only = False

  try:
    build_date = None
    if sys.argv[1] == '--from':
      sys.argv.pop(1)
      try:
        build_date = parse_date(sys.argv.pop(1))
      except ValueError:
        fail("Build date should be in the format YYYY-MM-DD.")
    if sys.argv[1] == '--verbose':
      sys.argv.pop(1)
      verbose = True
    if sys.argv[1] == '--print-url-only':
      sys.argv.pop(1)
      print_url_only = True
    build_type = sys.argv[1].lower()
    product = sys.argv[2].lower()
    version = sys.argv[3]
    try:
      qualifier = sys.argv[4]
    except IndexError:
      qualifier = None

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

    # The FLORIDA test-node-plugins artifact is only available as a jar.
    if product == 'test-node-plugins':
      package_type = "jar"

    repo = Repository(build_type, repository_type, organization)
    try:
      if version.lower() == 'latest':
        latest_version = repo.get_versions(product, verbose=verbose)[0].vstring
        artifact = repo.get_latest(product, latest_version, qualifier,
                                   package_type, verbose=verbose)
      elif version.endswith(".x"):
        artifact = repo.get_latest_from_pattern(product, version, qualifier,
                                                package_type, verbose=verbose)
      else:
        if build_date is not None:
          artifact = repo.get_from_date(product, version, qualifier,
              package_type, build_date, verbose=verbose)
        else:
          artifact = repo.get_latest(product, version, qualifier, package_type,
                                     verbose=verbose)
      if not print_url_only:
        artifact.download(verbose=verbose)
      else:
        print artifact.uri
    except KeyboardInterrupt:
      sys.stderr.write("\nDownload cancelled.\n")
  except (BuildTypeError, ProductTypeError), e:
    fail(str(e))
  except IndexError:
    _usage()

if __name__ == "__main__":
  main()

