#!/usr/bin/env python

import random
import string
import optparse
import csv
from geocoder import geocode



def generatenames(numtimes, namesfile, addrfile=None):
    tempint = 0
    num = numtimes
    file = namesfile
    listofnames = []
    listofaddresses = []
    generatednames = []
    members = []
    try:
        infile = open(file, 'r')
        outfile =  open('geocodes.csv', 'wb')
        memberfile = open('members.csv', 'wb')
        addressfile = open(addrfile, 'r')

        for address in addressfile:
            listofaddresses.append(string.strip(address))

        for name in infile:
            listofnames.append(string.strip(name))

        while tempint != num:
            rnum1 = random.randint(1,len(listofnames)-1)
            rnum2 = random.randint(1,len(listofnames)-1)
            rnum3 = random.randint(1,len(listofaddresses)-1)
            generatednames.append (listofnames[rnum1][0:1] +  listofnames[rnum2][1:] + ',' + listofaddresses[rnum3])
            members.append(listofnames[rnum1][0:1] +  listofnames[rnum2][1:] + ',' + listofnames[rnum1] + ',' + listofnames[rnum2] + ',R!chm0nd' + ',True' + ',' + listofnames[rnum1][0:1] + listofnames[rnum2][1:] + '@test.com')
            tempint += 1
        for name in members:
            print name
            memberfile.write(name+'\r\n')
        print '\r\n'
        print 'File members.csv successfully written!'
        print '\r\n' * 2
        for name in generatednames:
            outfile.write(name+'\r\n')
    except IOError as e:
        print 'ERROR! File %s does not exist!' % e


def main():
    p = optparse.OptionParser()
    p.add_option('-x', help='Specify number of random names to generate.', type='int', dest='times', default=None)
    p.add_option('-n', help='Specify filename that contains names.', dest='names', default=None)
    p.add_option('-a', help='Specify filename that contains addresses.', dest='addresses',default=None)
    (opts, args) = p.parse_args()

    generatenames(opts.times, opts.names, opts.addresses)
    print '=' * 40
    print 'Generating Geocodes.'
    print '=' * 40
    geocode('geocodes.csv')

    print """
    Two important files were created.  members.csv and geocodes.csv.out
    members.csv can be loaded using the SOAP client membercreate.  (Be Sure to modify soap.props first)
    geocodes.csv.out can be loaded using the SQLBulkLoader after the members are created.
        """

if __name__ == '__main__':
    main()