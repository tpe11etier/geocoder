#!/usr/bin/env python

from geopy import geocoders
import csv
import sys
import time

 
def geocode(filename):
    """
    Geoocder will use geopy and googles API to retrieve geocodes for addresses provided in a properly formatted csv file.
    An example of a properly formatted entry is:
    Shompson,13 HORSESHOE RD,, Chelmsford, MA, 01824,USA,,,
    username,address1,address2,city,state,zip,country,,,
    """
    g = geocoders.Google()
    writer = csv.writer(open(filename + ".out", "w"))

    try:
        reader = csv.reader(open(filename, "r"))
        for row in reader:
            if row: # Checking to see if it's a valid row so it doesn't blow up on an empty row.
                username, address, address2, city, state, zip, country = row[0:7]
                location = address + ', ' + city + ' ' + state + ' ' + zip + ' ' + country
                try:
                    place, (lat, lng) =  g.geocode(location) # Contact Google for Geocodes
                    time.sleep(.05)
                    la, lo = (lat, lng)
                    x = username, address, address2, city, state, zip, country, la, lo
                    print x
                    writer.writerow(x) #Write out records that now include Geocodes.
                except Exception as e:
                    print "An error has occurred: %s" % e
                    break
        print "File " + filename + ".out successfully written!"
    except IOError as e:
        print "Unable to open file: %s" % e

def main():
    if len(sys.argv) < 2:
        print "Provide a csv filename to read in.  eg. geocoder.py test.csv"
    else:
        filename = sys.argv[1]
        geocode(filename)

if __name__ == '__main__':
    main()