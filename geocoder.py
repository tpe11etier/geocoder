#!/usr/bin/env python

from geopy import geocoders
import csv
import sys


def geocode(filename):
    g = geocoders.Google()
    writer = csv.writer(open(filename + ".out", "wb"))

    try:
        reader = csv.reader(open(filename, "r"))
        for row in reader:
            if row: # Checking to see if it's a valid row so it doesn't blow up on an empty row.
                username, address, address2, city, state, zip, country = row[0:7]
                location = address + ', ' + city + ' ' + state + ' ' + zip + ' ' + country
                try:
                    place, (lat, lng) =  g.geocode(location) # Contact Google for Geocodes
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