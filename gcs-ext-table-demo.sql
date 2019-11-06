--
-- Demonstrate Kognitio internal and external tables on GCP
--
-- NOTE: the external tables require read / write permissions on the bucket to
--       be granted to the Kognitio containers. 
--       If you are running on an EKS cluster, the easiest way to do this is to use
--       the "--scopes=storage-rw" option when creating the cluster.
--
-- Run this script connected as the SYS user
--

DROP SCHEMA star_trek cascade;

CREATE SCHEMA star_trek;

--
-- Create an internal table and insert some data
--
CREATE TABLE star_trek.character_list(
  title VARCHAR(10),
  main_series VARCHAR(8),
  yob SMALLINT,
  species VARCHAR(7),
  name VARCHAR(15)
);

INSERT INTO star_trek.character_list
VALUES ('Captain','Original',2233,'Human','James T. Kirk')
      ,('Commander','Original',2230,'Vulcan','Spock')
      ,('Doctor','Original',2227,'Human','Leonard McCoy')
      ,('Captain','TNG',2305,'Human','Jean-Luc Picard')
      ,('Commander','TNG',2338,'Android','Data')
      ,('Commander','TNG',2340,'Klingon','Worf')
      ,('Ambassador','Original',2165,'Vulcan','Sarek')
      ,('Doctor','TNG',2324,'Human','Beverly Crusher')
      ,('Commander','Voyager',2264,'Vulcan','Tuvok')
      ,('Lieutenant','Voyager',2349,'Klingon','B''Elanna Torres')
      ,('Lieutenant','TNG',2348,'Human','Wesley Crusher')
      ,('Lieutenant','Voyager',2349,'Human','Harry Kim');
      
select * from star_trek.character_list;

--
-- create external table connectors for GCP buckets
--  NOTE: you need to change the bucket name (kognitio-examples) to one you've created in the project
--        your Kognitio server cluster is running in
--

-- create a block (csv) connector 
create module hadoop;
alter module hadoop set mode active;

create connector gcs_block 
source hdfs
target '
  namenode gs://kognitio-examples
';

-- create connectors for orc and parquet files 
create module java;
alter module java set mode to active;

create connector gcs_orc 
source java 
target '
  class com.kognitio.javad.jet.OrcConnector, 
  uri_location gs://kognitio-examples
';

create connector gcs_parquet
source java 
target '
  class com.kognitio.javad.jet.ParquetConnector, 
  uri_location gs://kognitio-examples
';

--
-- create some external tables
--

create external table star_trek.csv(
  title VARCHAR,
  main_series VARCHAR,
  yob SMALLINT,
  species VARCHAR,
  name VARCHAR
)
for insert
from gcs_block target '
  uri_path "/star-trek/csv/"
';

insert into star_trek.csv select * from star_trek.character_list;

select * from star_trek.csv;

-- you should now be able to see a file in <your bucket>/star-trek/csv/ which has CSV data in it
-- if the file already existed, you could use the definition above (removing for insert) to 
-- create a table to select from it.

-- create an external table using ORC files

create external table star_trek.orc(
  title VARCHAR,
  main_series VARCHAR,
  yob SMALLINT,
  species VARCHAR,
  name VARCHAR
)
for insert
from gcs_orc target '
  uri_path "/star-trek/orc/"
';

insert into star_trek.orc select * from star_trek.character_list;

select * from star_trek.orc;

-- you should now be able to see a file in <your bucket>/star-trek/orc/ which has data stored in ORC columnar format in it
-- because ORC (and Parquet) are columnar files, we don't need to specify the columns in the table definition when reading

create external table star_trek.orc_reader
from gcs_orc target '
  uri_path "/star-trek/orc/"
';

select * from star_trek.orc_reader;

-- create a partitioned external table with Parquet files

create external table star_trek.parquet_by_species(
  title VARCHAR,
  main_series VARCHAR,
  yob SMALLINT,
  species VARCHAR,
  name VARCHAR
)
for insert
from gcs_parquet
target '
  uri_path "/star-trek/parquet-by-species/"
  fmt_filename_partitions "species"
';

insert into star_trek.parquet_by_species select * from star_trek.character_list;

select * from star_trek.parquet_by_species;

-- <your bucket>/star-trek/parquet-by-species/ will now contain a directory for each species in the format
-- "species=Android/" and each will contain a parquet file containing data for that species

-- create a table to read a single species
create external table star_trek.parquet_android
from gcs_parquet
target '
  uri_path "/star-trek/parquet-by-species/species=Android/"
';

select * from star_trek.parquet_android;

-- note that the species column is missing, this is because the species column is stored in the directory 
-- structure and not the data file. 
-- Adding the "fmt_filename_partitions" target string option back in instructs the 
-- external table connector to look for the species column in the directory structure.

create external table star_trek.parquet_android_partitioned
from gcs_parquet
target '
  uri_path "/star-trek/parquet-by-species/species=Android/"
  fmt_filename_partitions "species"
';

select * from star_trek.parquet_android_partitioned;

-- to read all the partitions, simply point at the original directory

create external table star_trek.parquet_android_partitioned_reader
from gcs_parquet
target '
  uri_path "/star-trek/parquet-by-species/"
  fmt_filename_partitions "species"
';

select * from star_trek.parquet_android_partitioned_reader;


-- the partition structure is the standard Hive defined structure and so can be used to read tables
-- created by Hive or in the Hive format. Please note - some Hive tables stored as ORC do not have
-- the column names stored in the files (https://issues.apache.org/jira/browse/HIVE-7189) and require 
-- the columns to be specified for reading

