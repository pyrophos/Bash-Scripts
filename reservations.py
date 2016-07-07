#!/usr/bin/env python
"""A CLI Nebraska client that lists your current server reservations."""

import getpass
import requests
import sys

from clint.textui import colored
from clint.textui import columns
from datetime import datetime
from datetime import timedelta
from requests.auth import HTTPBasicAuth

#######################################################################
#
# Configuration
#
#######################################################################

__version__ = "1.0"

BASE_API_URL = 'https://nebraska.unboundid.lab/api/v1'

# HTTP client settings
HTTP_USER_AGENT = "Nebraska Reservations Client/%s" % __version__

# HTTP auth settings
HTTP_AUTH_USERNAME = "aponcy"
HTTP_AUTH_PASSWORD = ""

#######################################################################
#
# Everything else
#
#######################################################################

class NebraskaClient(object):
  """Client class for the Nebraska REST API."""
  def __init__(self, username, password):
    self.username = username
    self.password = password
    self.headers = {
        "User-Agent": HTTP_USER_AGENT,
        "Accept": "application/json"
    }
    self.verify_ssl_certs = False
    self.auth = HTTPBasicAuth(username, password)

  def get_user_id(self, user):
    """Retrieves the ID of the given username."""
    url = BASE_API_URL + '/user/?username=' + user
    r = requests.get(url, auth=self.auth,
                     headers=self.headers, verify=self.verify_ssl_certs)
    return r.json()['objects'][0]['id']

  def get_reservations(self, user_id):
    """Retrieves the user's reservations."""
    url = BASE_API_URL + '/reservation/?reserved_by=' + user_id
    r = requests.get(url, auth=self.auth,
                     headers=self.headers, verify=self.verify_ssl_certs)
    return r.json()

  def show_reservations(self, user):
    """Prints the user's current reservations."""
    user_id = self.get_user_id(user)
    reservations = self.get_reservations(user_id)
    col1width = 16
    col2width = 44
    col3width = 12
    print(columns([colored.green('Server'), col1width],
                  [colored.green('Notes'), col2width],
                  [colored.green('Ends'), col3width]))
    for reservation in reservations['objects']:
      end_date = datetime.strptime(reservation['end_date'], '%Y-%m-%d')
      now = datetime.now()
      if (end_date - now) > timedelta(days=1):
        print(columns([colored.cyan(reservation['server']['name']), col1width],
                      [reservation['notes'], col2width],
                      [reservation['end_date'], col3width]))

def main():
  if not HTTP_AUTH_USERNAME:
    login_name = raw_input("Username: ")
  else:
    login_name = HTTP_AUTH_USERNAME
  if not HTTP_AUTH_PASSWORD:
    password = getpass.getpass("Password: ")
  else:
    password = HTTP_AUTH_PASSWORD

  try:
    username = sys.argv[1]
  except IndexError:
    username = login_name

  client = NebraskaClient(login_name, password)
  client.show_reservations(username)


if __name__ == "__main__":
  main()
