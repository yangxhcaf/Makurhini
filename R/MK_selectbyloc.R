#' Select layer by location
#'
#' @param target object of class sf, sfc, sfg or SpatialPolygons.The selection will be applied to this layer.
#' @param sourcelyr object of class sf, sfc, sfg or SpatialPolygons.The features in the target layer will be selected based on their relationship to the features from this layer.
#' @param id character. Column name of the Core ID.
#' @param selreg character. "M1" select by intersect or "M2" select by intersect considering an umbral of intersection (thintersect parameter).
#' In both options you can choose a transboundary buffer.
#' @param buffer numeric. If "M2" is selected, you can choose a buffer for sourcelyr layer (optional).
#' @param thintersect numeric. If "M2" is selected, threshold of intersection in percentage allowed to select or not a target geometry. For example,
#' if a value of 90 then if the intersection area is equal or greater than 90 percent, the geometry will be selected.
#' @param transboundary numeric. Transboundary buffer to select polygones in a second round. See, Saura et al. 2017.
#' Transboundary field is added where 0 = Transboundary.
#' @param area_unit character. Attribute area units. You can set an area unit, "Makurhini::unit_covert()" compatible unit ("m2", "Dam2, "km2", "ha", "inch2", "foot2", "yard2", "mile2"). Default equal to hectares "ha".
#' @param plot logical. Default = FALSE. 1 = Not transboundary PA, 0 = Transboundary PA
#' @param write_select character. Write shapefile, provide folder direction, and name plus extension of the output shapefile
#' @param SAGA Logical. Optimize the large process using SAGA GIS and RSAGA package (see, \url{https://github.com/r-spatial/RSAGA}).
#' @return shapefile of selected geometries and intersected areas (default equal to hectares)
#' @examples
#' \dontrun{
#' library(Makurhini)
#' library(raster)
#' data("Protected_areas", package = "Makurhini")
#' plot(cores, col="green")
#'
#' data("regions", package = "Makurhini")
#' region <- regions[1,]
#' plot(region, col="blue")
#'
#' #Select protected areas
#' selection <- MK_selectbyloc(target = Protected_areas, sourcelyr = region, selreg = "M1")
#' plot(selection, col="green", add=TRUE)
#' }
#' @export
#' @importFrom magrittr %>%
#' @importFrom sf st_as_sf st_cast st_zm st_buffer write_sf st_intersection st_difference st_area st_intersects st_geometry
#' @importFrom sp over geometry
#' @importFrom rgeos gBuffer
#' @importFrom RSAGA rsaga.intersect.polygons
#' @importFrom dplyr mutate group_by summarize
#' @importFrom tibble as_tibble
#' @importFrom methods as
#' @importFrom rlang .data
MK_selectbyloc <- function(target, sourcelyr, id = NULL, selreg = "M1",
                        buffer = NULL, thintersect = NULL,
                        transboundary = NULL,  area_unit = "ha",
                        write_select = NULL, plot = FALSE,
                        SAGA = FALSE){
  options(warn = -1)
  err <- tryCatch(detach("package:plyr", unload=TRUE), error = function(err)err)

  ###
  '%!in%' <- function(x,y)!('%in%'(x,y))
  over_sf <- function(x, y) {
    if(class(x)[1] == "SpatialPolygonsDataFrame") {
      x <- st_as_sf(x)
    }

    if(class(y)[1] == "SpatialPolygonsDataFrame") {
      y <- st_as_sf(y) %>% st_cast("POLYGON")

    }
    over_result <- sapply(st_intersects(x, st_geometry(y)), function(z) if (length(z)==0) NA_integer_ else z[1])

    return(over_result)
  }

  ###
  if(is.null(thintersect)){
    thintersect = 0
  }

  if (class(target)[1] == "sf") {
    target <- st_zm(target)
    target <- as(target, 'Spatial')
  }
  if (class(sourcelyr)[1] == "sf") {
    sourcelyr <- st_zm(sourcelyr)
    sourcelyr <- as(sourcelyr, 'Spatial')
  }

  if(is.null(id)){
    target$IDTemp <- 1:length(target)
  } else {
    target$IDTemp <- target@data[,which(colnames(target@data) == id)]
  }

  #Selection method
  if (selreg == "M1") {
    select <- tryCatch(st_as_sf(target[!is.na(over(target, geometry(sourcelyr))),]), error = function(err)err)

    #######
    if (inherits(select, "error")){
      sourcelyr <- st_buffer(st_as_sf(sourcelyr), dist = 0)
      target <- st_buffer(st_as_sf(target), dist = 0)
      select <- st_as_sf(target[!is.na(over(as(target, 'Spatial'), geometry(as(sourcelyr, 'Spatial')))),])
    }

    if(nrow(select) >= 1){
      if (!is.null(transboundary)){
        if(length(select$IDTemp) > 0){
          select$transboundary <- 1
        }
        sourcelyr.2 <- st_buffer(st_as_sf(sourcelyr), dist = transboundary)
        sourcelyr.2 <- st_difference(sourcelyr.2, st_as_sf(sourcelyr))
        target.2 <- target[which(target$IDTemp %!in% select$IDTemp),]

        if (nrow(target.2) >= 1) {
          select.2 <- tryCatch(target.2[!is.na(over_sf(target.2, sourcelyr.2)),], error = function(err)err)

          if (inherits(select.2, "error")){
            sourcelyr.2 <- st_buffer(sourcelyr.2, dist = 0)
            target.2 <- st_buffer(st_as_sf(target.2), dist = 0)
            select.2 <- tryCatch(target.2[!is.na(over_sf(target.2, sourcelyr.2)),], error = function(err)err)
            if (inherits(select.2, "error")){
              target.2 <- target[which(target$IDTemp %!in% select$IDTemp),]
              target.3 <- gBuffer(as(target.2, 'Spatial'), width = 0)
              select.2 <- st_as_sf(target.3[!is.na(over(as(target.3, 'Spatial'),
                                                        geometry(as(sourcelyr.2, 'Spatial')))),])
              select.2$IDTemp <- select.2$rmapshaperid + 1
              select.2$rmapshaperid <- NULL
            }
          }

          if(length(select.2$IDTemp) > 0){
            select.2$transboundary <- 0
          }
          select <- rbind(select, st_as_sf(select.2))
        }
      }
    }
  } else if (selreg == "M2") {
    sourcelyr <- st_as_sf(sourcelyr) %>% st_zm() %>% st_cast("POLYGON")
    #Option 1
    if (!is.null(buffer) & is.null(transboundary)){
      sourcelyr <- st_buffer(sourcelyr, dist = buffer)
      select.1 <- tryCatch(st_as_sf(target[!is.na(over_sf(target, sourcelyr)),]), error = function(err)err)
      if (inherits(select.1, "error")){
        sourcelyr <- st_buffer(sourcelyr, dist = 0)
        target <- st_buffer(st_as_sf(target), dist = 0)
        select.1 <- st_as_sf(target[!is.na(over_sf(target, sourcelyr)),])
      }

      if(nrow(select.1) >= 1){
        select.1$A <- unit_convert(as.numeric(st_area(select.1, by_element = TRUE)), "m2", area_unit)

        if (isFALSE(SAGA)){
          #Intersections
          select.1 <- select.1
          sourcelyr <- sourcelyr %>% st_cast("POLYGON")
          intersection_percentage <- tryCatch(st_intersection(select.1, sourcelyr), error = function(err)err)

          if (inherits(intersection_percentage, "error")){
            select.1 <- st_buffer(select.1, dist = 0)
            sourcelyr <- st_buffer(sourcelyr, dist = 0) %>% st_cast("POLYGON")
            intersection_percentage <- st_intersection(select.1, sourcelyr)
          }

        } else {
          dir_tmp <- paste0(tempdir(), "/out")
          if(dir.exists(dir_tmp)){
            unlink(dir_tmp, recursive = TRUE)
          }
          dir.create(dir_tmp, recursive = TRUE)
          save_tmp <- paste0(dir_tmp, "/out.shp")
          intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.1, 'Spatial'), layer_b = as(sourcelyr, 'Spatial'),
                                                                       result = save_tmp, load = TRUE), error = function(err)err)
          if (inherits(intersection_percentage, "error")){
            select.1 <- st_buffer(select.1, dist = 0)
            sourcelyr <- st_buffer(sourcelyr, dist = 0) %>% st_cast("POLYGON")
            intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.1, 'Spatial'), layer_b = as(sourcelyr, 'Spatial'),
                                                                         result = save_tmp, load = TRUE), error = function(err)err)
          }
          intersection_percentage <- st_as_sf(intersection_percentage)
        }

        intersection_percentage <- intersection_percentage %>%
          mutate(A2 = unit_convert(as.numeric(st_area(.)), "m2", area_unit) %>% as.numeric()) %>%
          as_tibble() %>% group_by(.data$IDTemp) %>%
          dplyr::summarize(Area1 = sum(.data$A), Area2 = sum(.data$A2))
        intersection_percentage$PercPi <- as.numeric((intersection_percentage$Area2 * 100) / intersection_percentage$Area1)

        select.1 <- merge(select.1, intersection_percentage, by = "IDTemp")
        if(!is.null(select.1$PercPi[is.na(select.1$PercPi)])){
          select.1$PercPi[is.na(select.1$PercPi)] <- 0
        }

        select <- select.1[select.1$PercPi >= thintersect,]
        select[,"A"] <- list(NULL)
      } else{
        select <- select.1
      }

      ####
      #Option 2
    } else if (is.null(buffer) & !is.null(transboundary)){
      select.1 <-  tryCatch(st_as_sf(target[!is.na(over_sf(target, sourcelyr)),]),
                            error = function(err)err)

      if (inherits(select.1, "error")){
        sourcelyr <- st_buffer(sourcelyr, dist = 0)
        target <- st_buffer(st_as_sf(target), dist = 0)
        select.1 <- st_as_sf(target[!is.na(over_sf(target, sourcelyr)),])
      }

      if(nrow(select.1) >= 1){
        select.1$A <- unit_convert(as.numeric(st_area(select.1, by_element = TRUE)), "m2", area_unit)

        if (isFALSE(SAGA)){
          sourcelyr <- sourcelyr %>% st_cast("POLYGON")

          intersection_percentage <- tryCatch(st_intersection(select.1, sourcelyr), error = function(err)err)

          if (inherits(intersection_percentage, "error")){
            select.1 <- st_buffer(select.1, dist = 0)
            sourcelyr <- st_buffer(sourcelyr, dist = 0)
            intersection_percentage <- st_intersection(select.1, sourcelyr)
          }

        } else {
          dir_tmp <- paste0(tempdir(), "/out")
          if(dir.exists(dir_tmp)){
            unlink(dir_tmp, recursive = TRUE)
          }

          dir.create(dir_tmp, recursive = TRUE)
          save_tmp <- paste0(dir_tmp, "/out.shp")
          intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.1, 'Spatial'), layer_b = as(sourcelyr, 'Spatial'),
                                                                       result = save_tmp, load = TRUE), error = function(err)err)
          if (inherits(intersection_percentage, "error")){
            select.1 <- st_buffer(select.1, dist = 0)
            sourcelyr <- st_buffer(sourcelyr, dist = 0)
            intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.1, 'Spatial'), layer_b = as(sourcelyr, 'Spatial'),
                                                                         result = save_tmp, load = TRUE), error = function(err)err)
          }
          intersection_percentage <- st_as_sf(intersection_percentage)
        }

        intersection_percentage <- intersection_percentage %>%
          mutate(A2 = unit_convert(as.numeric(st_area(.)), "m2", area_unit) %>% as.numeric()) %>%
          as_tibble() %>% group_by(.data$IDTemp) %>%
          dplyr::summarize(Area1 = sum(.data$A), Area2 = sum(.data$A2))

        intersection_percentage$PercPi <- as.numeric((intersection_percentage$Area2 * 100) / intersection_percentage$Area1)
        select.1 <- merge(select.1, intersection_percentage, by = "IDTemp")

        if(!is.null(select.1$PercPi[is.na(select.1$PercPi)])){
          select.1$PercPi[is.na(select.1$PercPi)] <- 0
        }

        select <- select.1[select.1$PercPi >= thintersect,]
        select[,c("A")] <- list(NULL)
        if(length(select$IDTemp) > 0){
          select$transboundary <- 1
        }

        #Second selection. Transboundary
        sourcelyr.2 <- st_buffer(sourcelyr, dist = transboundary)
        sourcelyr.2 <- st_difference(sourcelyr.2, sourcelyr)
        target.2  <- target[which(target$IDTemp %!in% select$IDTemp),]#Get PA not selected yet

        if (nrow(target.2) >= 1){
          select.2 <- tryCatch(st_as_sf(target.2[!is.na(over_sf(target.2, sourcelyr.2)),]), error = function(err)err)

          if (inherits(select.2, "error")){
            sourcelyr.2 <- st_buffer(sourcelyr.2, dist = 0)
            target.2 <- st_buffer(st_as_sf(target.2), dist = 0)
            select.2 <- tryCatch(st_as_sf(target.2[!is.na(over_sf(target.2, sourcelyr.2)),]), error = function(err)err)

            if (inherits(select.2, "error")){
              target.2  <- target[which(target$IDTemp %!in% select$IDTemp),]
              target.3 <- gBuffer(target.2, width = 0)
              target.3$id <- 1
              plt <- nrow(target.3)
              target.3$id <- NULL
              if (nrow(target.2) > 1 | plt == 1){
                target.3 <- st_as_sf(target.3) %>% st_cast("POLYGON")
              }
              select.2 <- st_as_sf(target.3[!is.na(over(as(target.3, 'Spatial'),
                                                        geometry(as(sourcelyr.2, 'Spatial')))),])
              select.2$IDTemp <- select.2$rmapshaperid + 1
              select.2$rmapshaperid <- NULL
            }
          }

          select.2$A <- unit_convert(as.numeric(st_area(select.2, by_element = TRUE)), "m2", area_unit)

          if (isFALSE(SAGA)){
            select.2 <- select.2
            sourcelyr.2 <- sourcelyr.2 %>% st_cast("POLYGON")
            intersection_percentage <- tryCatch(st_intersection(select.2, sourcelyr.2), error = function(err)err)
            if (inherits(intersection_percentage, "error")){
              select.2 <- st_buffer(select.2, dist = 0)
              sourcelyr.2 <- st_buffer(sourcelyr.2, dist = 0) %>% st_cast("POLYGON")
              intersection_percentage <- st_intersection(select.2, sourcelyr.2)
            }
          } else {
            dir_tmp <- paste0(tempdir(), "/out")
            if(dir.exists(dir_tmp)){
              unlink(dir_tmp, recursive = TRUE)
            }

            dir.create(dir_tmp, recursive = TRUE)
            save_tmp <- paste0(dir_tmp, "/out.shp")
            intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.2, 'Spatial'), layer_b = as(sourcelyr.2, 'Spatial'),
                                                                         result = save_tmp, load = TRUE), error = function(err)err)
            if (inherits(intersection_percentage, "error")){
              select.2 <- st_buffer(select.2, dist = 0)
              sourcelyr.2 <- st_buffer(sourcelyr.2, dist = 0) %>% st_cast("POLYGON")
              intersection_percentage <- tryCatch(rsaga.intersect.polygons(layer_a = as(select.2, 'Spatial'), layer_b = as(sourcelyr.2, 'Spatial'),
                                                                           result = save_tmp, load = TRUE), error = function(err)err)
            }
            intersection_percentage <- st_as_sf(intersection_percentage)%>% st_cast("POLYGON")
          }

          intersection_percentage <- intersection_percentage %>%
            mutate(A2 = unit_convert(as.numeric(st_area(.)), "m2", area_unit) %>% as.numeric())%>%
            as_tibble() %>% group_by(.data$IDTemp) %>%
            dplyr::summarize(Area1 = sum(.data$A), Area2 = sum(.data$A2))

          intersection_percentage$PercPi <- as.numeric((intersection_percentage$Area2*100) / intersection_percentage$Area1)
          select.2 <- merge(select.2, intersection_percentage, by = "IDTemp")

          select.2 <- select.2[select.2$PercPi >= thintersect,]
          select.2[,"A"] <- list(NULL)
          if(length(select.2$IDTemp) > 0){
            select.2$transboundary <- 0
          }

          select <- rbind(select, select.2)

        }
      } else {
        select <- select.1
      }
    } else {
      stop("Error, just select an option: buffer or transboundary")
    }
  } else {
    stop("Error, select selreg model")
  }
  #
  if (nrow(select) >= 1){
    if(isTRUE(plot) & !is.null(transboundary)){
      plot(select["transboundary"])
    }

    if (!is.null(write_select)){
      write_sf(select, write_select, delete_layer = TRUE)
    }
    select$IDTemp <- 1:nrow(select)
  }
  return(select)
}
